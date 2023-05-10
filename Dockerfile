#syntax=docker/dockerfile:1.4

# The different stages of this Dockerfile are meant to be built into separate images
# https://docs.docker.com/develop/develop-images/multistage-build/#stop-at-a-specific-build-stage
# https://docs.docker.com/compose/compose-file/#target

# Builder images
FROM composer/composer:2-bin AS composer
ARG PHP_VERSION="8.2"
ENV PHP_VERSION ${PHP_VERSION}
# Prod image
FROM php:${PHP_VERSION}fpm-alpine AS app_php

ENV APP_ENV=prod

WORKDIR /srv/app

# persistent / runtime deps
RUN apk add --no-cache --virtual buildDeps autoconf \
            freetype \
            libpng \
            libjpeg-turbo \
            freetype-dev \
            libpng-dev \
            jpeg-dev \
            libwebp-dev \
            libjpeg \
            libjpeg-turbo-dev \
            icu-dev \
            libzip-dev \
            zip \
            acl \
            shadow \
            build-base \
            linux-headers \
            fcgi \
    		file \
    		gettext \
    		git \
     ;

RUN  docker-php-ext-configure gd --enable-gd --with-freetype --with-jpeg --with-webp \
     && docker-php-ext-install gd \
     && docker-php-ext-install opcache \
     && docker-php-ext-install pdo pdo_mysql \
     && docker-php-ext-configure intl && docker-php-ext-install intl \
     && docker-php-ext-configure zip\
     && docker-php-ext-install zip

# install APCu from pecl
RUN apk add --update --no-cache --virtual .build-dependencies $PHPIZE_DEPS \
        && pecl install apcu \
        && docker-php-ext-enable apcu \
        && pecl clear-cache \
        && apk del .build-dependencies

RUN usermod -u 1000 www-data



###> recipes ###
###< recipes ###

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
COPY --link docker/php/conf.d/app.ini $PHP_INI_DIR/conf.d/
COPY --link docker/php/conf.d/app.prod.ini $PHP_INI_DIR/conf.d/

COPY --link docker/php/php-fpm.d/zz-docker.conf /usr/local/etc/php-fpm.d/zz-docker.conf
RUN mkdir -p /var/run/php

COPY --link docker/php/docker-healthcheck.sh /usr/local/bin/docker-healthcheck
RUN chmod +x /usr/local/bin/docker-healthcheck

HEALTHCHECK --interval=10s --timeout=3s --retries=3 CMD ["docker-healthcheck"]

COPY --link docker/php/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint

ENTRYPOINT ["docker-entrypoint"]
CMD ["php-fpm"]

# https://getcomposer.org/doc/03-cli.md#composer-allow-superuser
ENV COMPOSER_ALLOW_SUPERUSER=1
ENV PATH="${PATH}:/root/.composer/vendor/bin"

COPY --from=composer --link /composer /usr/bin/composer

# prevent the reinstallation of vendors at every changes in the source code
COPY --link composer.* ./
RUN set -eux; \
    if [ -f composer.json ]; then \
		composer install --prefer-dist --no-dev --no-autoloader --no-scripts --no-progress; \
		composer clear-cache; \
    fi

# copy sources
COPY --link  . ./
RUN rm -Rf docker/

RUN set -eux; \
	mkdir -p var/cache var/log; \
    if [ -f composer.json ]; then \
		composer dump-autoload --classmap-authoritative --no-dev; \
		composer dump-env prod; \
		composer run-script --no-dev post-install-cmd; \
		chmod +x bin/console; sync; \
    fi

# Dev image
FROM app_php AS app_php_dev

ENV APP_ENV=dev XDEBUG_MODE=off
VOLUME /srv/app/var/

RUN rm "$PHP_INI_DIR/conf.d/app.prod.ini"; \
	mv "$PHP_INI_DIR/php.ini" "$PHP_INI_DIR/php.ini-production"; \
	mv "$PHP_INI_DIR/php.ini-development" "$PHP_INI_DIR/php.ini"

COPY --link docker/php/conf.d/app.dev.ini $PHP_INI_DIR/conf.d/

RUN apk add --no-cache \
            busybox-extras \
            mysql-client \
     ;


# install xdebug
RUN pecl install xdebug \
&& docker-php-ext-enable xdebug


RUN rm -f .env.local.php

# Caddy image
FROM nginx:1.24.0 AS app_nginx

WORKDIR /srv/app


COPY --from=app_php --link /srv/app/public public/
