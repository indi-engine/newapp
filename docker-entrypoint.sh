#!/bin/bash

# If $RABBITMQ_HOST is not given - start rabbitmq server right here
[ -z "$RABBITMQ_HOST" ] && service rabbitmq-server start

# If $MYSQL_HOST is not given - start mysql right here as well
[ -z "$MYSQL_HOST" ] && /usr/local/bin/docker-entrypoint.sh mysqld &

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

# Obtain Let's Encrypt certificate, if LE_DOMAIN env is given:
# 1.Start apache in background to make certbot challenge possible
# 2.Obtain certificate
# 3.Stop apache in backgrond
# 4.Setup cron job for certificate renewal check
if [[ ! -z "$LETS_ENCRYPT_DOMAIN" ]]; then
  service apache2 start
  certbot --apache -n -d $LETS_ENCRYPT_DOMAIN -m $GIT_COMMIT_EMAIL --agree-tos -v
  service apache2 stop
  echo "0 */12 * * * certbot renew" | crontab -
fi

# Setup crontab
env | grep -E "(MYSQL|RABBITMQ)_HOST|GIT_COMMIT_(NAME|EMAIL)|DOC" >> /etc/environment
jobs='compose/crontab'
sed -i "s~\$DOC~$DOC~" $jobs && crontab -u $user $jobs && $run 'git checkout '$jobs
service cron start

# Start apache process
echo "Apache started" && apachectl -D FOREGROUND