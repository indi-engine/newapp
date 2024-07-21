#!/bin/bash

# Set ownership here, as current dir is a volume so Dockerfile's chown doesn't take effect
echo "Running chown.."
chown -R $user:$user ..

# Command prefix to run something on behalf on www-data user
run='/sbin/runuser '$user' -s /bin/bash -c'

# Setup git commit author identity
if [[ ! -z "$GIT_COMMIT_NAME"   && -z $($run 'git config user.name')  ]]; then $run 'git config --global user.name  "$GIT_COMMIT_NAME"' ; fi
if [[ ! -z "$GIT_COMMIT_EMAIL"  && -z $($run 'git config user.email') ]]; then $run 'git config --global user.email "$GIT_COMMIT_EMAIL"'; fi

# Setup git filemode
$run 'git config --global core.filemode false'

# Remove debug.txt file, if exists, and create log/ directory if not exists
$run 'if [[ -f "debug.txt" ]] ; then rm debug.txt ; fi'
$run 'if [[ ! -d "log" ]] ; then mkdir log ; fi'

# If '../vendor'-dir is not yet moved back to /var/www - do move
$run 'if [[ ! -d "vendor" && -d "../vendor" ]] ; then echo "Moving ../vendor back here..." ; mv ../vendor vendor ; echo "Moved." ; fi'

# If '../.idea'-dir is not yet moved back to /var/www - do move
$run 'if [[ ! -d ".idea" && -d "../.idea" ]] ; then echo "Moving ../.idea back here..." ; mv ../.idea .idea ; echo "Moved." ; fi'

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

# Trim leading/trailing whitespaces from domain name(s)
LETS_ENCRYPT_DOMAIN=$(echo "$LETS_ENCRYPT_DOMAIN" | xargs)
EMAIL_SENDER_DOMAIN=$(echo "$EMAIL_SENDER_DOMAIN" | xargs)

# Obtain Let's Encrypt certificate, if LETS_ENCRYPT_DOMAIN env is not empty:
if [[ ! -z "$LETS_ENCRYPT_DOMAIN" ]]; then

  # Insert/update ServerAlias directive for default vhost
  # and start apache in background to make certbot challenge possible
  conf="/etc/apache2/sites-available/000-default.conf"
  if ! grep -q "ServerAlias" <<< "$(<"$conf")"; then
    sed -i "s~ServerAdmin.*~&\n\tServerAlias $LETS_ENCRYPT_DOMAIN~" $conf
  else
    sed -i "s~ServerAlias.*~ServerAlias $LETS_ENCRYPT_DOMAIN~" $conf
  fi
  service apache2 start

  # Obtain certificate and stop apache in background
  # and setup cron job for certificate renewal check
  domainsArg=$(echo "$LETS_ENCRYPT_DOMAIN" | sed 's/ / -d /g')
  certbot --apache -n -d $domainsArg -m "$GIT_COMMIT_EMAIL" --agree-tos -v
  service apache2 stop
  echo "0 */12 * * * certbot renew" | crontab -

  # If $EMAIL_SENDER_DOMAIN is empty - use LETS_ENCRYPT_DOMAIN by default
  if [[ -z "$EMAIL_SENDER_DOMAIN" ]]; then EMAIL_SENDER_DOMAIN=$LETS_ENCRYPT_DOMAIN; fi
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

# Setup crontab
env | grep -E "(MYSQL|RABBITMQ)_HOST|GIT_COMMIT_(NAME|EMAIL)|DOC" >> /etc/environment
jobs='compose/crontab'
sed -i "s~\$DOC~$DOC~" $jobs && crontab -u $user $jobs && $run 'git checkout '$jobs
service cron start

# Start opendkim and postfix to be able to send DKIM-signed emails via sendmail used by php
if [[ -f "/etc/opendkim/trusted.hosts" ]]; then service opendkim start; fi
service postfix start

# Start apache process
echo "Apache started" && apachectl -D FOREGROUND