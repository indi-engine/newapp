FROM php:8.3-apache-bookworm

## <Misc> ##
RUN apt-get update && apt-get install -fy certbot cron python3-certbot-apache mc git
## </Misc> ##

## <User> ##
ENV user www-data
RUN usermod -s /bin/bash $user
## </User> ##

## <Apache> ##
ARG DOC
ENV DOC $DOC
WORKDIR /etc/apache2
RUN echo "ServerName indi-engine"      >> apache2.conf  && \
    echo "<Directory $DOC>"            >> apache2.conf  && \
    echo "  AllowOverride All"         >> apache2.conf  && \
    echo "</Directory>"                >> apache2.conf  && \
    rm conf-enabled/other-vhosts-access-log.conf        && \
    cp mods-available/rewrite.load        mods-enabled/ && \
    cp mods-available/headers.load        mods-enabled/ && \
    cp mods-available/proxy.load          mods-enabled/ && \
    cp mods-available/proxy_http.load     mods-enabled/ && \
    cp mods-available/proxy_wstunnel.load mods-enabled/ && \
    echo "export HOME=/var/www"        >> envvars
WORKDIR $DOC
## </Apache> ##

## <PHP extensions> ##
RUN apt-get update && \
    apt-get install -y libfreetype-dev libjpeg62-turbo-dev libpng-dev libzip-dev libicu-dev && \
    docker-php-ext-configure gd --with-freetype --with-jpeg && \
    docker-php-ext-install -j$(nproc) gd zip pdo_mysql shmop intl sockets && \
    apt-get install -y libmagickwand-dev imagemagick && pecl install imagick && docker-php-ext-enable imagick
## </PHP extensions> ##

## <JRE> ##
RUN apt-get install -y default-jre
## </JRE> ##

## <Composer> ##
ARG GH_TOKEN_SYSTEM
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
 && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
 && php -r "unlink('composer-setup.php');"
COPY custom .
RUN composer config github-oauth.github.com $GH_TOKEN_SYSTEM
RUN composer install
RUN sed -Ei 's~\t(filemode|pushurl)\s*=\s*.*~~I' vendor/indi-engine/client/.git/config && \
  sed -Ei 's~\t(filemode|pushurl)\s*=\s*.*~~I' vendor/indi-engine/system/.git/config && \
  mv vendor ../vendor
## </Composer> ##

## <Sendmail> ##
RUN bash -c "DEBIAN_FRONTEND=noninteractive apt install -y postfix <<< $'2' && apt install -y opendkim opendkim-tools"
## </Sendmail> ##

# Use custom entrypoint
ENTRYPOINT ["bash", "custom-entrypoint.sh"]
