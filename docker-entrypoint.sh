#!/bin/bash

# Remove debug.txt file, if exists, and create log/ directory if not exists
/sbin/runuser www-data -s /bin/bash -c 'if [[ -f "debug.txt" ]] ; then rm debug.txt ; fi'
/sbin/runuser www-data -s /bin/bash -c 'if [[ ! -d "log" ]] ; then mkdir log ; fi'

# If $RABBITMQ_HOST is given
if [ -n "$RABBITMQ_HOST" ]; then

  # Extract the RabbitMQ port from application/config.ini
  port=$(grep -Pzo "(?s)\[rabbitmq\].*?port.*?\K[0-9]+" application/config.ini | tr -d '\0')

  # Print rabbitmq port found
  echo "RabbitMQ port is $port"

  # Wait for RabbitMQ to be ready in separate container
  while ! ncat -z $RABBITMQ_HOST $port >/dev/null 2>&1; do echo "Waiting for RabbitMQ..." && sleep 5; done

# Else start rabbitmq right here
else service rabbitmq-server start; fi

# If $MYSQL_HOST is not given - start mysql right here as well
[ -z "$MYSQL_HOST" ] && /usr/local/bin/docker-entrypoint.sh mysqld &

# Start php background processes
/sbin/runuser www-data -s /bin/bash -c "php indi -d realtime/closetab"
/sbin/runuser www-data -s /bin/bash -c "php indi realtime/maxwell/enable"

# Apache pid-file
pid_file="/var/run/apache2/apache2.pid"

# Remove pid-file, if kept from previous start of apache container
if [ -f "$pid_file" ]; then rm "$pid_file" && echo "Apache old pid-file removed"; fi

# Start apache process
apachectl -D FOREGROUND