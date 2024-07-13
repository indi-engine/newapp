FROM debian:12-slim

## <Misc> ##
RUN apt-get update && apt-get install -fy mc curl wget lsb-release cron certbot python3-certbot-apache
## </Misc> ##

## <User> ##
ENV user www-data
RUN usermod -s /bin/bash $user
## </User> ##

## <Apache> ##
ARG DOC
ENV DOC $DOC
RUN apt-get install -y apache2
WORKDIR /etc/apache2
RUN echo "ServerName indi-engine"      >> apache2.conf  && \
    echo "<Directory $DOC>"            >> apache2.conf  && \
    echo "  AllowOverride All"         >> apache2.conf  && \
    echo "</Directory>"                >> apache2.conf  && \
    cp mods-available/rewrite.load        mods-enabled/ && \
    cp mods-available/headers.load        mods-enabled/ && \
    cp mods-available/proxy.load          mods-enabled/ && \
    cp mods-available/proxy_http.load     mods-enabled/ && \
    cp mods-available/proxy_wstunnel.load mods-enabled/ && \
    echo "export HOME=/var/www"        >> envvars
WORKDIR $DOC
## </Apache> ##

## <PHP> ##
RUN wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg && \
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list && \
    apt update && apt -y install php8.3 php8.3-mysql php8.3-curl php8.3-mbstring php8.3-dom php8.3-gd php8.3-zip php8.3-imagick php8.3-intl && \
    update-alternatives --set php /usr/bin/php8.3
## </PHP> ##

## <JRE> ##
RUN apt-get install -y default-jre
## </JRE> ##

## <GitHub CLI>
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt update && apt install gh -y
## </GitHub CLI>

## <Composer> ##
RUN apt -y install composer
COPY composer.json composer.lock .
RUN chown -R $user:$user ..
USER $user
RUN composer install && \
  sed -Ei 's~\t(filemode|pushurl)\s*=\s*.*~~I' vendor/indi-engine/client/.git/config && \
  sed -Ei 's~\t(filemode|pushurl)\s*=\s*.*~~I' vendor/indi-engine/system/.git/config && \
  mv vendor ../vendor && \
  mv .idea  ../.idea
## </Composer> ##

## <IndiEngine> ##
USER root
COPY . .
RUN chown -R $user .
## </IndiEngine> ##

## <Sendmail> ##
RUN bash -c "apt install -y postfix <<< $'2' && apt install -y opendkim opendkim-tools"
## </Sendmail> ##

ENTRYPOINT $DOC/docker-entrypoint.sh
EXPOSE 80