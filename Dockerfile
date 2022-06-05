## <MySQL> ##
FROM mysql:8.0.29 as builder
RUN ["sed", "-i", "s/exec \"$@\"/echo \"not running $@\"/", "/usr/local/bin/docker-entrypoint.sh"]
ENV MYSQL_ROOT_PASSWORD=root
WORKDIR /docker-entrypoint-initdb.d
ADD https://github.com/indi-engine/system/raw/master/sql/system.sql system.sql
RUN chmod 777 system.sql
RUN prepend="\
  CREATE DATABASE ``custom`` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci; \n \
  CREATE USER 'custom'@'localhost' IDENTIFIED BY 'custom'; \n \
  GRANT ALL ON ``custom``.* TO 'custom'@'localhost'; \n \
  USE ``custom``;" && sed -i.old '1 i\'"$prepend" system.sql
RUN ["/usr/local/bin/docker-entrypoint.sh", "mysqld", "--datadir", "/prefilled-db"]
FROM mysql:8.0.29
RUN echo 'sql-mode=STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION' >> /etc/mysql/my.cnf
COPY --from=builder /prefilled-db /var/lib/mysql
## </MySQL> ##

## <Misc> ##
RUN apt-get update && apt-get install -fy mc curl wget lsb-release
## </Misc> ##

## <Apache> ##
RUN apt-get install -y apache2
WORKDIR /etc/apache2
RUN echo "ServerName indi-engine"      >> apache2.conf  && \
    echo "<Directory /var/www/html>"   >> apache2.conf  && \
    echo "  AllowOverride All"         >> apache2.conf  && \
    echo "</Directory>"                >> apache2.conf  && \
    cp mods-available/rewrite.load        mods-enabled/ && \
    cp mods-available/headers.load        mods-enabled/ && \
    cp mods-available/proxy.load          mods-enabled/ && \
    cp mods-available/proxy_http.load     mods-enabled/ && \
    cp mods-available/proxy_wstunnel.load mods-enabled/
## </Apache> ##

## <PHP> ##
RUN wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg && \
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list && \
    apt update && apt -y install php7.4 php7.4-mysql php7.4-curl php7.4-mbstring php7.4-dom php7.4-gd php7.4-zip
## </PHP> ##

## <RabbitMQ> ##
RUN curl -1sLf 'https://dl.cloudsmith.io/public/rabbitmq/rabbitmq-erlang/setup.deb.sh' | /bin/bash
RUN curl -1sLf 'https://dl.cloudsmith.io/public/rabbitmq/rabbitmq-server/setup.deb.sh' | /bin/bash
ENV rmqv 1:24.3.4-1
RUN apt-get install -y --fix-missing erlang-base=$rmqv erlang-asn1=$rmqv erlang-crypto=$rmqv erlang-eldap=$rmqv \
    erlang-ftp=$rmqv erlang-inets=$rmqv erlang-mnesia=$rmqv erlang-os-mon=$rmqv erlang-parsetools=$rmqv \
    erlang-public-key=$rmqv erlang-runtime-tools=$rmqv erlang-snmp=$rmqv erlang-ssl=$rmqv erlang-syntax-tools=$rmqv \
    erlang-tftp=$rmqv erlang-tools=$rmqv erlang-xmerl=$rmqv rabbitmq-server
## </RabbitMQ> ##

## <IndiEngine> ##
WORKDIR /var/www/html
COPY . .
RUN [ ! -f "application/config.ini" ] && cp application/config.ini.example application/config.ini
RUN chown -R www-data .
## </IndiEngine> ##

## <Composer> ##
RUN apt -y install composer && [ ! -d "vendor" ] && composer install
### </Composer> ##

RUN chmod +x docker-entrypoint.sh && sed -i 's/\r$//' docker-entrypoint.sh
ENTRYPOINT ["/var/www/html/docker-entrypoint.sh"]
EXPOSE 80