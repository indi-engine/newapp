#!/bin/bash
for f in application/ws.* ; do rm "$f" ; done
rm debug.txt
export WSP=$(grep -Pzo "(?s)\[ws\].*?port.*?\K[0-9]+" application/config.ini | tr -d '\0')
service rabbitmq-server start
/sbin/runuser www-data -s /bin/bash -c "php vendor/indi-engine/system/application/ws.php > /dev/null &"
/usr/local/bin/docker-entrypoint.sh mysqld &
apachectl -D FOREGROUND