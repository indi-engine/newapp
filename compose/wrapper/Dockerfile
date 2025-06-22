FROM php:8.3-cli-bookworm

## <Misc> ##
RUN apt-get update && apt-get install -fy mc curl wget lsb-release cron bsdextrautils zip unzip jq python3-flask python3-pika python3-pexpect python3-pymysql p7zip-full

## </Misc> ##

## <GitHub CLI>
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt update && apt install gh -y
## </GitHub CLI>

## <Sendmail> ##
RUN bash -c "DEBIAN_FRONTEND=noninteractive apt install -y postfix <<< $'2' && apt install -y opendkim opendkim-tools"
## </Sendmail> ##

## <PHP extensions> ##
RUN apt-get update && \
    apt-get install -y libfreetype-dev libjpeg62-turbo-dev libpng-dev libzip-dev libicu-dev && \
    docker-php-ext-configure gd --with-freetype --with-jpeg && \
    docker-php-ext-install -j$(nproc) gd zip pdo_mysql shmop intl sockets && \
    apt-get install -y libmagickwand-dev imagemagick && pecl install imagick && docker-php-ext-enable imagick
## </PHP extensions> ##

## <Composer> ##
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
 && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
 && php -r "unlink('composer-setup.php');"
## <Composer> ##

## Setup entrypoint ##
ENTRYPOINT ["bash", "-c", "source $DOC/compose/wrapper/docker-entrypoint.sh"]
