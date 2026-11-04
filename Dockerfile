FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    DOTNET_ROOT=/usr/share/dotnet \
    PATH=/usr/share/dotnet:$PATH \
    LANG=C.UTF-8

# 1. Установка базовых утилит и добавление свежего репозитория PHP (PPA)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget unzip gnupg lsb-release jq openssl socat cron software-properties-common \
    && add-apt-repository ppa:ondrej/php -y \
    && apt-get update \
    && rm -rf /var/lib/apt/lists/*

# 2. Установка MariaDB, Apache и PHP 8.4 + модулей
RUN apt-get update && apt-get install -y --no-install-recommends \
    libicu-dev \
    mariadb-server mariadb-client \
    apache2 \
    php8.4 php8.4-cli libapache2-mod-php8.4 \
    php8.4-mysql php8.4-curl php8.4-mbstring php8.4-xml php8.4-gmp \
    php8.4-gd php8.4-zip php8.4-common \
    && rm -rf /var/lib/apt/lists/*

# Настройка PHP: правильный порядок загрузки модулей
RUN set -eux; \
    for ini in /etc/php/8.4/apache2/php.ini /etc/php/8.4/cli/php.ini; do \
        if [ -f "$ini" ]; then \
            # 1. Базовые модули (порядок критичен!)
            sed -i 's/^;extension=mysqlnd$/extension=mysqlnd/' "$ini" || true; \
            sed -i 's/^;extension=pdo$/extension=pdo/' "$ini" || true; \
            sed -i 's/^;extension=pdo_mysql$/extension=pdo_mysql/' "$ini" || true; \
            sed -i 's/^;extension=mysqli$/extension=mysqli/' "$ini" || true; \
            \
            # 2. Опциональные модули (есть .so файлы)
            sed -i 's/^;extension=curl$/extension=curl/' "$ini" || true; \
            sed -i 's/^;extension=mbstring$/extension=mbstring/' "$ini" || true; \
            sed -i 's/^;extension=gmp$/extension=gmp/' "$ini" || true; \
            sed -i 's/^;extension=gd$/extension=gd/' "$ini" || true; \
            sed -i 's/^;extension=zip$/extension=zip/' "$ini" || true; \
            \
            # 3. УБИРАЕМ встроенные модули (openssl, sodium уже в бинарнике PHP 8.4)
            # Иначе PHP пытается загрузить их как .so и выдаёт warning
            sed -i 's/^extension=openssl$/;extension=openssl ; built-in in PHP 8.4/' "$ini" || true; \
            sed -i 's/^extension=sodium$/;extension=sodium ; built-in in PHP 8.4/' "$ini" || true; \
            \
            # 4. Увеличиваем лимиты
            sed -i 's/memory_limit = 128M/memory_limit = 512M/g' "$ini" || true; \
            sed -i 's/upload_max_filesize = 2M/upload_max_filesize = 64M/g' "$ini" || true; \
            sed -i 's/post_max_size = 8M/post_max_size = 64M/g' "$ini" || true; \
        fi; \
    done; \
    a2enmod php8.4 2>/dev/null || true; \
    a2enmod rewrite ssl headers; \
    sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf; \
    echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf; \
    a2enconf servername; \
    mkdir -p \
        /var/www/html \
        /var/www/letsencrypt/.well-known/acme-challenge \
        /var/run/mysqld \
        /var/MikroBILL/cert \
        /var/MikroBILL/secrets; \
    chown -R mysql:mysql /var/run/mysqld; \
    chown -R www-data:www-data /var/www

# .NET 6 ASP.NET Core runtime
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh && \
    chmod +x /tmp/dotnet-install.sh && \
    /tmp/dotnet-install.sh --channel 6.0 --runtime aspnetcore --install-dir /usr/share/dotnet && \
    ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet && \
    rm /tmp/dotnet-install.sh

# Дистрибутив MikroBILL внутри образа
COPY stable.zip /tmp/stable.zip
RUN mkdir -p /opt/mikrobill-installer && \
    unzip -o /tmp/stable.zip -d /opt/mikrobill-installer && \
    rm -f /tmp/stable.zip

# acme.sh - установка
RUN curl -fsSL https://get.acme.sh | sh -s email=acme@example.com

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80 443 7402 3306

ENTRYPOINT ["/entrypoint.sh"]
