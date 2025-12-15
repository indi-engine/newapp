FROM indiengine/php:8.3-apache-bookworm

## <Composer> ##
ARG GH_TOKEN_SYSTEM_RO
RUN php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" \
 && php composer-setup.php --install-dir=/usr/local/bin --filename=composer \
 && php -r "unlink('composer-setup.php');"
COPY custom/public .
RUN composer config github-oauth.github.com $GH_TOKEN_SYSTEM_RO
RUN composer install
RUN sed -Ei 's~\t(filemode|pushurl)\s*=\s*.*~~I' vendor/indi-engine/client/.git/config && \
  sed -Ei 's~\t(filemode|pushurl)\s*=\s*.*~~I' vendor/indi-engine/system/.git/config && \
  mv vendor ../vendor
## </Composer> ##

# Use custom entrypoint
ENTRYPOINT ["bash", "custom-entrypoint.sh"]
