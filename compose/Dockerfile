FROM debian:11-slim

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
    apt update && apt -y install php7.4 php7.4-mysql php7.4-curl php7.4-mbstring php7.4-dom php7.4-gd php7.4-zip && \
    update-alternatives --set php /usr/bin/php7.4
## </PHP> ##

## <JRE> ##
RUN apt-get install -y default-jre
## </JRE> ##

## <IndiEngine> ##
WORKDIR /var/www/html
COPY . .
## </IndiEngine> ##

## <Composer> ##
ENV user www-data
RUN usermod -s /bin/bash $user && chown -R $user /var/www && apt -y install composer
USER $user
RUN composer install && mv vendor ../vendor
USER root
### </Composer> ##

ENTRYPOINT ["/var/www/html/docker-entrypoint.sh"]
EXPOSE 80