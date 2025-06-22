#!/bin/bash

# Setup git commit author identity
if [[ ! -z "$GIT_COMMIT_NAME"   && -z $(git config user.name)  ]]; then git config user.name  "$GIT_COMMIT_NAME" ; fi
if [[ ! -z "$GIT_COMMIT_EMAIL"  && -z $(git config user.email) ]]; then git config user.email "$GIT_COMMIT_EMAIL"; fi

# Setup git filemode
git config --global core.filemode false

# Copy 'mysql' and 'mysqldump' binaries to /usr/bin, to make it possible to restore/backup the whole database as sql-file
cp /usr/bin/mysql_client_binaries/* /usr/bin/

# Trim leading/trailing whitespaces from domain name(s)
LETS_ENCRYPT_DOMAIN=$(echo "$LETS_ENCRYPT_DOMAIN" | xargs)
EMAIL_SENDER_DOMAIN=$(echo "$EMAIL_SENDER_DOMAIN" | xargs)

# If $EMAIL_SENDER_DOMAIN is empty - use LETS_ENCRYPT_DOMAIN by default
if [[ ! -z "$LETS_ENCRYPT_DOMAIN" ]]; then
  if [[ -z "$EMAIL_SENDER_DOMAIN" ]]; then
    EMAIL_SENDER_DOMAIN=$LETS_ENCRYPT_DOMAIN
  fi
fi

# Configure postfix and opendkim to ensure outgoing emails deliverability
if [[ ! -z "$EMAIL_SENDER_DOMAIN" ]]; then

  # Shortcuts
  dkim="/etc/opendkim"
  selector="mail"
  conf="/etc/postfix/main.cf"
  sock="inet:localhost:8891"

  # If trusted.hosts file does not yet exist - it means we're setting up opendkim for the very first time
  if [[ ! -f "$dkim/trusted.hosts" ]]; then
    echo -e "127.0.0.1\nlocalhost" >> "$dkim/trusted.hosts"
  fi

  # Setup postfix to use opendkim as milter
  if ! grep -q $sock <<< "$(<"$conf")"; then
    echo -e "smtpd_milters = $sock\nnon_smtpd_milters = $sock" >> $conf
  fi

  # Split LETS_ENCRYPT_DOMAIN into an array
  IFS=' ' read -r -a senders <<< "$EMAIL_SENDER_DOMAIN"

  # Use first item of that array as myhostname in postfix config
  # This is executed on container (re)start so you can apply new value without container re-creation
  sed -Ei "s~(myhostname\s*=)\s*.*~\1 ${senders[0]}~" "/etc/postfix/main.cf"

  # Iterate over each domain for postfix and opendkim configuration
  for maildomain in "${senders[@]}"; do
    domainkeys="$dkim/keys/$maildomain"
    priv="$domainkeys/$selector.private"
    DNSname="$selector._domainkey.$maildomain"

    # If private key file was not generated so far
    if [[ ! -f $priv ]]; then
      # Generate key files
      mkdir -p $domainkeys
      opendkim-genkey -D $domainkeys -s $selector -d $maildomain
      chown opendkim:opendkim $priv
      chown $user:$user "$domainkeys/$selector.txt"

      # Setup key.table, signing.table and trusted.hosts files to be picked by opendkim
      echo "$DNSname $maildomain:$selector:$priv"   >> "$dkim/key.table"
      echo "*@$maildomain $DNSname"                 >> "$dkim/signing.table"
      echo "*.$maildomain"                          >> "$dkim/trusted.hosts"
    fi
  done
fi

# Start opendkim and postfix to be able to send DKIM-signed emails via sendmail
if [[ -f "/etc/opendkim/trusted.hosts" ]]; then service opendkim start; fi
service postfix start

# Load functions and define empty releaseQty assoc array
source maintain/functions.sh

# Export GH_TOKEN from $GH_TOKEN_CUSTOM
[[ ! -z $GH_TOKEN_CUSTOM ]] && export GH_TOKEN="${GH_TOKEN_CUSTOM:-}"

# Setup crontab
export TERM=xterm && env | grep -E "MYSQL|GIT|GH|DOC|EMAIL|TERM|BACKUPS|APP_ENV" >> /etc/environment
sed "s~\$DOC~$DOC~" 'compose/wrapper/crontab' | crontab -
service cron start

# If GH_TOKEN is set it means we'll work via GitHub CLI, so set current repo as default one for that tool
if [[ -n $GH_TOKEN ]]; then
  gh repo set-default "$(get_current_repo)"
fi

# Make sure 'custom/data/upload' dir is created and filled, if does not exist
init_uploads_if_need

# If $GH_TOKEN_CUSTOM is set but there are no releases yet in the current repo due to it's
# a forked or generated repo and it's a very first time of the instance getting
# up and running for the current repo - backup current state into a very first own release,
# so that any further deployments won't rely on parent repo releases anymore
make_very_first_release_if_need

# Run HTTP api server
FLASK_APP=compose/wrapper/api.py flask run --host=0.0.0.0 --port=80