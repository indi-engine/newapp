# Do imports
from flask import Flask, request, jsonify
import subprocess, pika, json, pexpect, re, pymysql, os, shlex
from pika.exceptions import ChannelClosedByBroker

# Instantiate Flask app
app = Flask(__name__)
app.config["JSON_SORT_KEYS"] = False

# Get parent repo
def get_current_repo():
    return subprocess.run(
        'source maintain/functions.sh && get_current_repo',
        shell=True, executable='/bin/bash', capture_output=True, text=True
    ).stdout.strip()

# Get current repo
def get_parent_repo():
    return subprocess.run(
        'source maintain/functions.sh && get_parent_repo "$(get_current_repo)"',
        shell=True, executable='/bin/bash', capture_output=True, text=True
    ).stdout.strip()

# Check tag syntax
def valid_tag(tagName):
    return bool(re.fullmatch(r'[a-zA-Z0-9._-]{1,63}', tagName))

# Check if given queue exists, i.e. user didn't closed the browser tab yet
def queue_exists(channel, name):
    try:
        channel.queue_declare(queue=name, passive=True)
        return True, channel
    except ChannelClosedByBroker:
        return False, channel.connection.channel()

# Get value of given variable from .env file
def get_dot_env(name):
    with open('.env') as f:
        for line in f:
            if line.startswith(name + '='):
                value = line.strip().split('=', 1)[1]

                # Remove optional surrounding single or double quotes
                if (value.startswith('"') and value.endswith('"')) or \
                   (value.startswith("'") and value.endswith("'")):
                    value = value[1:-1]

                # Return value with trimmed surrounding single/double quotes
                return value
    return ''

# Send websocket message to open xterm in Indi Engine UI
def ws(to, data, mq, mysql):

    # Queue name prefix
    prefix = 'indi-engine.custom.opentab--'

    # If title-prop exist in data - save for later reuse
    if 'title' in data:
        ws.title = data['title']

    # Set up initial value for refresh flag
    if to['token']:
        exists, mq = queue_exists(mq, prefix + to['token'])
        refresh = not exists
        if refresh:
            mysql.execute("DELETE FROM `realtime` WHERE `type` = 'channel' AND `token` = %s", (to['token']))
    else:
        refresh = True

    # If token should be refreshed
    if refresh:

        # Get browser tab, if any opened by the user that can be identified by that pair
        mysql.execute(
            "SELECT `token` FROM `realtime` WHERE `type` = 'channel' AND `roleId` = %s AND `adminId` = %s",
            (to['roleId'], to['adminId'])
        )

        # If at least one found - refresh token
        if mysql.rowcount:
            to['token'] = mysql.fetchone()['token']

    # Append title
    if 'title' not in data:
        data['title'] = ws.title

    # Send message
    mq.basic_publish(
        exchange = '',
        routing_key = prefix + to['token'],
        body = json.dumps(data)
    )

    # Return rabbitmq channel (existing or new)
    return mq

# Spawn bash script and stream stdout/stderr to a websocket channel
def bash_stream(
    command,
    data
):
    # Connect to RabbitMQ
    nn = pika.BlockingConnection(pika.ConnectionParameters('rabbitmq'))
    mq = nn.channel()

    # Instantiate mysql connection with db cursor
    mysql_conn = pymysql.connect(host='mysql', user='custom', password='custom', database='custom', autocommit=True)
    mysql = mysql_conn.cursor(pymysql.cursors.DictCursor)

    # Start bash script in a pseudo-terminal
    child = pexpect.spawn('bash -c "' + command + '"', encoding='utf-8')

    # Recipient definition
    to=data.get('to')

    # Send websocket message to open xterm in Indi Engine UI
    mq = ws(to, data, mq, mysql)

    # While script is running
    while True:
        try:

            # Read as many bytes as written by script
            bytes = child.read_nonblocking(size=1024, timeout=180)

            # If script has finished and no bytes were read
            # (maybe just before the PTY fully closed),
            # but EOF was not raised yet - break the loop
            if not bytes and not child.isalive():
                break

            # Send websocket message to open xterm in Indi Engine UI
            mq = ws(to, {
                'type': data.get('type'),
                'id': data.get('id'),
                'bytes': bytes
            }, mq, mysql)

        # If pexpect is SURE the script is done and the PTY is closed - break the loop
        except pexpect.EOF:
            break

    # Close script process
    child.close()

    # Indicate all done, if all done
    if child.exitstatus == 0 and child.signalstatus is None:

        # Default msg
        bytes = 'All done.'

        # If it was update-command and container changes are required by restart scenario - change default msg
        if (re.search(r'source update', command) and os.path.exists('var/restart')):
            with open("var/restart", "r") as f: scenario = int(f.read())
            if scenario == 4:
                bytes = "Doing it. Please wait for 'Reconnected' message in the bottom-left corner."
            elif scenario != 5:
                bytes = "Doing it. Please wait for 'Proceed to re-login' prompt and click OK there then."
    else:
        bytes = ''

    # Make terminal closable in any case
    mq = ws(to, {
        'type': data.get('type'),
        'id': data.get('id'),
        'bytes': bytes,
        'closable': True
    }, mq, mysql)

    # If it's a restore-command that affected database state - send ws-message to reload windows and menu
    if (
        re.search(r' source restore ', command)
        and child.exitstatus == 0 and child.signalstatus is None
        and data.get('scenario') in ['full', 'dump', 'cancel']
    ):
        mq = ws(to, {'type': 'restored'}, mq, mysql)

    # Clone rabbitmq connection
    nn.close()

    # Close mysql cursor and connection
    mysql.close()
    mysql_conn.close()

    # Return
    return 'Executed', 200

# Add backup endpoint
@app.route('/backup', methods=['POST'])
def backup():

    # Get json data
    data = request.get_json(silent=True) or {}

    # Basic backup command
    command = 'source backup'

    # If scenario is to patch the most recent backup with current database (or current uploads) - add to command
    if data.get('scenario') in ['dump', 'uploads']:
        command += f" {data.get('scenario')} --recent"

    # If repo param is given - prepend as variable
    if data.get('token'): command = f"TOKEN={shlex.quote(data.get('token'))} {command}"

    # If repo param is given - prepend as variable
    if data.get('repo'): command = f"REPO={shlex.quote(data.get('repo'))} {command}"

    # Run bash script and stream stdout/stderr
    return bash_stream(command, data)

# Get restore status
@app.route('/restore/status', methods=['GET'])
def restore_status():

    # Get branch
    branch = subprocess.run(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], capture_output=True, text=True)

    # If something went wrong - flush failure
    if branch.returncode != 0:
        return jsonify({'success': False, 'msg': branch.stderr}), 500

    # Get notes
    notes = subprocess.run(['git', 'notes', 'show'], capture_output=True, text=True)

    # Chec and return json
    if (
        branch.stdout.strip() == 'HEAD'
        and notes.returncode == 0
        and re.search(r' · [a-f0-9]{7}$', notes.stdout.strip())
    ):
        return json.dumps({
           'is_uncommitted_restore': True,
           'version': notes.stdout.strip()
        }, ensure_ascii=False), 200
    else:
        return json.dumps({
           'is_uncommitted_restore': False,
           'version': ''
        }, ensure_ascii=False), 200

# Get restore choices
@app.route('/restore/choices', methods=['GET'])
def restore_choices():

    # Prepare choices object
    choices = {'current': {'name': get_current_repo(), 'list': []}}

    # Get GH_TOKEN_CUSTOM_RW from .env
    token = get_dot_env('GH_TOKEN_CUSTOM_RW')

    # Prepare curl command
    command = ['curl']
    if bool(token): command += ['-H', f'Authorization: Bearer {token}']
    command += ['-sS', '--fail-with-body', url := 'https://api.github.com/repos/' + choices['current']['name'] + '/releases']

    # Get restore choices list for current repo
    list = subprocess.run(command, capture_output=True, text=True)

    # If something went wrong - flush failure
    if list.returncode != 0:
        return jsonify({
            'success': False,
            'msg': list.stderr + url + '\n' + json.loads(list.stdout.strip())['message'].replace(". (", ".\n(")
        }), 500
    else: choices['current']['list'] = json.loads(list.stdout.strip())

    # Try to detect parent repo
    parent_repo = get_parent_repo()

    # If detected
    if (parent_repo not in ["null", "indi-engine/newapp"]):

        # Append 'parent'-key into choices object
        choices['parent'] = {'name': parent_repo, 'list': []}

        # Get GH_TOKEN_PARENT_RO from .env
        token = get_dot_env('GH_TOKEN_PARENT_RO')

        # Prepare curl command
        command = ['curl']
        if bool(token): command += ['-H', f'Authorization: Bearer {token}']
        command += ['-sS', '--fail-with-body', url := 'https://api.github.com/repos/' + choices['parent']['name'] + '/releases']

        # Get restore choices list for current repo
        list = subprocess.run(command, capture_output=True, text=True)

        # If something went wrong - flush failure
        if list.returncode != 0: return jsonify({'success': False, 'msg': list.stderr}), 500
        else: choices['parent']['list'] = json.loads(list.stdout.strip())

    # Cache choices
    with open('var/tmp/choices.json', 'w') as file: file.write(json.dumps(choices))

    # Return output
    return json.dumps(choices, indent=2), 200

# Do restore
@app.route('/restore', methods=['POST'])
def restore():

    # Get json data
    data = request.get_json(silent=True) or {}

    # Basic restore command
    command = 'CACHED=1 source restore'

    # If name param is given - prepend as variable
    if data.get('name'): command = f"GIT_COMMIT_NAME={shlex.quote(data.get('name'))} {command}"

    # If email param is given - prepend as variable
    if data.get('email'): command = f"GIT_COMMIT_EMAIL={shlex.quote(data.get('email'))} {command}"

    # If scenario is to restore just the database (or uploads), or to commit/cancel the restore - add to command
    if data.get('scenario') in ['dump', 'uploads', 'commit', 'cancel']:
        command += f" {data.get('scenario')}"

    # If scenario is not 'commit' or 'cancel'
    if data.get('scenario') in ['full', 'dump', 'uploads']:
        if valid_tag(data.get('tagName')): command += f" {data.get('tagName')}"
        else: return jsonify({'success': False, 'msg': 'Invalid tag name'}), 400

    # If parent-flag is given as true - append '--parent' flag to restore command
    if data.get('parent') == True:
        command += ' --parent'

    # Run bash script and stream stdout/stderr
    return bash_stream(command, data)

@app.route('/backup/status', methods=['GET'])
def backup_status():

    # Return backup status as current repo name and has_token flag
    return jsonify({
        'success': True,
        'repo': get_current_repo(),
        'has_token': bool(get_dot_env('GH_TOKEN_CUSTOM_RW')),
        'GH_ASSET_MAX_SIZE': get_dot_env('GH_ASSET_MAX_SIZE')
    }), 200

@app.route('/commit/identity', methods=['GET'])
def commit_identity():

    # Return backup status as current repo name and has_token flag
    return jsonify({
        'success': True,
        'GIT_COMMIT_NAME': get_dot_env('GIT_COMMIT_NAME'),
        'GIT_COMMIT_EMAIL': get_dot_env('GIT_COMMIT_EMAIL')
    }), 200

# Get mysql import status
@app.route('/import/done', methods=['GET'])
def import_done():
    return '', 200 if os.path.exists('/var/lib/mysql/import.done') else 404

# Update and migrate, if need
@app.route('/update', methods=['POST'])
def update():

    # Get json data
    data = request.get_json(silent=True) or {}

    # Basic update command
    command = 'source update'

    # If name param is given - prepend as variable
    if data.get('name'): command = f"GIT_COMMIT_NAME={shlex.quote(data.get('name'))} {command}"

    # If email param is given - prepend as variable
    if data.get('email'): command = f"GIT_COMMIT_EMAIL={shlex.quote(data.get('email'))} {command}"

    # Run bash script and stream stdout/stderr
    return bash_stream(command, data)
