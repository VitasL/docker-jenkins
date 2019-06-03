FROM jenkins/jenkins:alpine
MAINTAINER Jason <jason@gymoo.cn>

# Jenkins is using jenkins user, we need root to install things.
USER root

# timezone
ENV TIMEZONE Asia/Shanghai
RUN apk add --no-cache tzdata \
    && ln -snf /usr/share/zoneinfo/$TIMEZONE /etc/localtime \
    && echo $TIMEZONE > /etc/timezone

# zip unzip
RUN apk add --no-cache zip unzip

######################## Docker in Docker ########################

RUN apk add --no-cache \
    ca-certificates

RUN [ ! -e /etc/nsswitch.conf ] && echo 'hosts: files dns' > /etc/nsswitch.conf

ENV DOCKER_CHANNEL edge
ENV DOCKER_VERSION 18.02.0-ce
ENV DOCKER_HOST_ADDRESS "docker:2375"
ENV DOCKER_HOST "tcp://$DOCKER_HOST_ADDRESS"

RUN set -ex; \
  apk add --no-cache --virtual .fetch-deps \
    curl \
    tar \
  ; \
  \
  apkArch="$(apk --print-arch)"; \
  case "$apkArch" in \
    x86_64) dockerArch='x86_64' ;; \
    armhf) dockerArch='armel' ;; \
    aarch64) dockerArch='aarch64' ;; \
    ppc64le) dockerArch='ppc64le' ;; \
    s390x) dockerArch='s390x' ;; \
    *) echo >&2 "error: unsupported architecture ($apkArch)"; exit 1 ;;\
  esac; \
  \
  if ! curl -fL -o docker.tgz "https://download.docker.com/linux/static/${DOCKER_CHANNEL}/${dockerArch}/docker-${DOCKER_VERSION}.tgz"; then \
    echo >&2 "error: failed to download 'docker-${DOCKER_VERSION}' from '${DOCKER_CHANNEL}' for '${dockerArch}'"; \
    exit 1; \
  fi; \
  \
  tar --extract \
    --file docker.tgz \
    --strip-components 1 \
    --directory /usr/local/bin/ \
  ; \
  rm docker.tgz; \
  \
  apk del .fetch-deps; \
  \
  dockerd -v; \
  docker -v

######################## Maven and Gradle ########################

ENV MAVEN_VERSION 3.5.4
ENV GRADLE_VERSION 4.6

RUN apk add --no-cache --virtual .maven-gradle-deps wget curl tar unzip \
  && mkdir /maven \
  && curl http://mirror.bit.edu.cn/apache/maven/maven-3/$MAVEN_VERSION/binaries/apache-maven-$MAVEN_VERSION-bin.tar.gz | tar xzf - -C /maven --strip-components=1 \
  && ln -s /maven/bin/mvn /usr/bin/mvn \
  && wget -q https://services.gradle.org/distributions/gradle-$GRADLE_VERSION-bin.zip \
  && unzip -q gradle-$GRADLE_VERSION-bin.zip \
  && rm -rf gradle-$GRADLE_VERSION-bin.zip \
  && mv gradle-$GRADLE_VERSION gradle \
  && ln -s /gradle/bin/gradle /usr/bin/gradle \
  && apk del .maven-gradle-deps

############################## PHP and Composer ##############################

ENV PHPIZE_DEPS \
    autoconf \
    dpkg-dev dpkg \
    file \
    g++ \
    gcc \
    libc-dev \
    make \
    pkgconf \
    re2c

RUN apk add --no-cache --virtual .persistent-deps \
    ca-certificates \
    curl \
    tar \
    xz \
    libressl

RUN set -x \
  && addgroup -g 82 -S www-data \
  && adduser -u 82 -D -S -G www-data www-data

ENV PHP_INI_DIR /usr/local/etc/php
RUN mkdir -p $PHP_INI_DIR/conf.d

ENV PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2"
ENV PHP_CPPFLAGS="$PHP_CFLAGS"
ENV PHP_LDFLAGS="-Wl,-O1 -Wl,--hash-style=both -pie"

ENV PHP_VERSION 5.6.38
ENV PHP_URL="https://secure.php.net/get/php-5.6.38.tar.xz/from/this/mirror"

RUN set -xe; \
  apk add --no-cache --virtual .fetch-deps \
    gnupg \
    wget \
  ; \
  mkdir -p /usr/src; \
  cd /usr/src; \
  wget -O php.tar.xz "$PHP_URL"; \
  apk del .fetch-deps

COPY php/docker-php-* /usr/local/bin/

RUN set -xe \
  && chmod +x /usr/local/bin/docker-php-* \
  && apk add --no-cache --virtual .build-deps \
    $PHPIZE_DEPS \
    coreutils \
    curl-dev \
    libedit-dev \
    libressl-dev \
    libxml2-dev \
    sqlite-dev \
  \
  && export CFLAGS="$PHP_CFLAGS" \
    CPPFLAGS="$PHP_CPPFLAGS" \
    LDFLAGS="$PHP_LDFLAGS" \
  && docker-php-source extract \
  && cd /usr/src/php \
  && gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)" \
  && ./configure \
    --build="$gnuArch" \
    --with-config-file-path="$PHP_INI_DIR" \
    --with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
    --enable-option-checking=fatal \
    --with-mhash \
    --enable-ftp \
    --enable-mbstring \
    --enable-mysqlnd \
    --with-curl \
    --with-libedit \
    --with-openssl \
    --with-zlib \
    \
    $(test "$gnuArch" = 's390x-linux-gnu' && echo '--without-pcre-jit') \
    \
    $PHP_EXTRA_CONFIGURE_ARGS \
  && make -j "$(nproc)" \
  && make install \
  && { find /usr/local/bin /usr/local/sbin -type f -perm +0111 -exec strip --strip-all '{}' + || true; } \
  && make clean \
  \
  && cp -v php.ini-* "$PHP_INI_DIR/" \
  && cd / \
  && docker-php-source delete \
  && runDeps="$( \
    scanelf --needed --nobanner --format '%n#p' --recursive /usr/local \
      | tr ',' '\n' \
      | sort -u \
      | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
  )" \
  && apk add --no-cache --virtual .php-rundeps $runDeps \
  && apk del .build-deps \
  && pecl update-channels \
  && rm -rf /tmp/pear ~/.pearrc


# mbstring opcache pdo mysql
RUN docker-php-ext-install mbstring opcache pdo pdo_mysql mysql mysqli
# gd zip
RUN apk add --no-cache freetype libpng libjpeg-turbo freetype-dev libpng-dev libjpeg-turbo-dev \
    && NPROC=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || 1) \
    && docker-php-ext-configure gd \
        --with-gd \
        --with-freetype-dir \
        --with-png-dir \
        --with-jpeg-dir \
        --with-zlib-dir \
    && docker-php-ext-install -j${NPROC} gd zip \
    && apk del freetype-dev libpng-dev libjpeg-turbo-dev


# composer
RUN apk add --no-cache --virtual .composer-deps curl \
  && mkdir /php-composer \
  && curl -sS https://getcomposer.org/installer | php -- --install-dir=/php-composer \
  && ln -s /php-composer/composer.phar /usr/bin/composer \
  && apk del .composer-deps

########################## Node and Yarn #########################

ENV NODE_VERSION 8.9.4
ENV YARN_VERSION 1.3.2

RUN apk add --no-cache \
        libstdc++ \
  && apk add --no-cache --virtual .build-deps \
        binutils-gold \
        curl \
        g++ \
        gcc \
        libgcc \
        linux-headers \
        make \
        python \
  && curl -SLO "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION.tar.xz" \
  && tar -xf "node-v$NODE_VERSION.tar.xz" \
  && cd "node-v$NODE_VERSION" \
  && ./configure \
  && make -j$(getconf _NPROCESSORS_ONLN) \
  && make install \
  && npm install cnpm -g --registry=https://registry.npm.taobao.org \
  && apk del .build-deps \
  && cd .. \
  && rm -Rf "node-v$NODE_VERSION" \
  && rm "node-v$NODE_VERSION.tar.xz"

RUN apk add --no-cache --virtual .build-deps-yarn \
        curl \
  && curl -fSLO --compressed "https://yarnpkg.com/downloads/$YARN_VERSION/yarn-v$YARN_VERSION.tar.gz" \
  && mkdir -p /opt/yarn \
  && tar -xzf yarn-v$YARN_VERSION.tar.gz -C /opt/yarn --strip-components=1 \
  && ln -s /opt/yarn/bin/yarn /usr/local/bin/yarn \
  && ln -s /opt/yarn/bin/yarn /usr/local/bin/yarnpkg \
  && rm yarn-v$YARN_VERSION.tar.gz \
  && apk del .build-deps-yarn

########################## SSH config #########################

RUN echo -e "\nHost *\n    StrictHostKeyChecking no\n    UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config

# Go back to jenkins user.
USER jenkins
