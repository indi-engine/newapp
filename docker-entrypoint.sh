#!/bin/bash

# If $RABBITMQ_HOST is not given - start rabbitmq server right here
[ -z "$RABBITMQ_HOST" ] && service rabbitmq-server start

# If $MYSQL_HOST is not given - start mysql right here as well
[ -z "$MYSQL_HOST" ] && /usr/local/bin/docker-entrypoint.sh mysqld &

# Set ownership here, as current dir is a volume so Dockerfile's chown doesn't take effect
echo "Running chown.."
chown $user .. && chown -R $user:$user .

# Setup git commit author identity
if [[ ! -z "$GIT_COMMIT_NAME"  && -z $(git config user.name) ]];   then git config user.name "$GIT_COMMIT_NAME"; fi
if [[ ! -z "$GIT_COMMIT_EMAIL" && -z $(git config user.email)  ]]; then git config user.email "$GIT_COMMIT_EMAIL"; fi

# Command prefix to run something on behalf on www-data user
run='/sbin/runuser '$user' -s /bin/bash -c'

# Remove debug.txt file, if exists, and create log/ directory if not exists
$run 'if [[ -f "debug.txt" ]] ; then rm debug.txt ; fi'
$run 'if [[ ! -d "log" ]] ; then mkdir log ; fi'

# If '../vendor'-dir is not yet moved back to /var/www - do move
$run 'if [[ ! -d "vendor" && -d "../vendor" ]] ; then echo "Moving ../vendor back here..." ; mv ../vendor vendor ; echo "Moved." ; fi'

# Copy config.ini file from example one, if not exist
$run 'if [[ ! -f "application/config.ini" ]] ; then cp application/config.ini.example application/config.ini ; fi'

# Start php background processes
$run 'php indi -d realtime/closetab'
$run 'php indi realtime/maxwell/enable'

# Apache pid-file
pid_file="/var/run/apache2/apache2.pid"

# Remove pid-file, if kept from previous start of apache container
if [ -f "$pid_file" ]; then rm "$pid_file" && echo "Apache old pid-file removed"; fi

# Copy 'mysql' and 'mysqldump' binaries to /usr/bin, to make it possible to restore/backup the whole database as sql-file
cp /usr/bin/mysql_client_binaries/* /usr/bin/

# Start apache process
echo "Apache started" && apachectl -D FOREGROUND