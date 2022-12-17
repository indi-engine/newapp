#!/bin/bash
rm debug.txt
service rabbitmq-server start
/sbin/runuser www-data -s /bin/bash -c "php indi -d realtime/closetab"
/sbin/runuser www-data -s /bin/bash -c "php indi realtime/maxwell/enable"
/usr/local/bin/docker-entrypoint.sh mysqld &
apachectl -D FOREGROUND