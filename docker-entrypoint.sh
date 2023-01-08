#!/bin/bash
service rabbitmq-server start
/usr/local/bin/docker-entrypoint.sh mysqld &
/sbin/runuser www-data -s /bin/bash -c 'if [[ -f "debug.txt" ]] ; then rm debug.txt ; fi'
/sbin/runuser www-data -s /bin/bash -c 'if [[ ! -d "log" ]] ; then mkdir log ; fi'
/sbin/runuser www-data -s /bin/bash -c "php indi -d realtime/closetab"
/sbin/runuser www-data -s /bin/bash -c "php indi realtime/maxwell/enable"
apachectl -D FOREGROUND