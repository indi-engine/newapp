#!/bin/bash
for f in application/ws.* ; do rm "$f" ; done
rm debug.txt
chmod 0777 . application
service rabbitmq-server start
php vendor/indi-engine/system/application/ws.php > /dev/null &
/usr/local/bin/docker-entrypoint.sh mysqld &
apachectl -D FOREGROUND