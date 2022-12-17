#!/bin/bash
rm debug.txt
service rabbitmq-server start
/sbin/runuser www-data -s /bin/bash -c "php indi -d realtime/closetab"
/usr/local/bin/docker-entrypoint.sh mysqld &
apachectl -D FOREGROUND