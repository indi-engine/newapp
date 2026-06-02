# syntax=docker/dockerfile:1
FROM indiengine/php:8.3-apache-bookworm

## <Composer> ##
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
 && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
 && php -r "unlink('composer-setup.php');"
COPY custom/public .
RUN --mount=type=secret,id=github_token \
    GITHUB_TOKEN=$(cat /run/secrets/github_token) && \
    export COMPOSER_AUTH='{"github-oauth":{"github.com":"'$GITHUB_TOKEN'"}}' && \
    composer install
RUN sed -Ei 's~\t(filemode|pushurl)\s*=\s*.*~~I' vendor/indi-engine/client/.git/config && \
  sed -Ei 's~\t(filemode|pushurl)\s*=\s*.*~~I' vendor/indi-engine/system/.git/config && \
  mv vendor ../vendor && \
  rm /usr/local/bin/composer
## </Composer> ##

# Use custom entrypoint
ENTRYPOINT ["bash", "custom-entrypoint.sh"]
