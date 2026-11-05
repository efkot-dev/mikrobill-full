FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    DOTNET_ROOT=/usr/share/dotnet \
    PATH=/usr/share/dotnet:$PATH \
    LANG=C.UTF-8

# 1. Базовые утилиты + репозиторий PHP (Sury = официальный зеркalo ondrej/php)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget unzip jq openssl \
    && install -d /etc/apt/keyrings \
    && curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/keyrings/sury-php.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ noble main" > /etc/apt/sources.list.d/sury-php.list \
    && rm -rf /var/lib/apt/lists/*

# 2. MariaDB, Apache, PHP 8.4 + модули по официальным требованиям MikroBILL
RUN apt-get update && apt-get install -y --no-install-recommends \
    mariadb-server mariadb-client \
    apache2 \
    php8.4 php8.4-cli libapache2-mod-php8.4 \
    php8.4-mysql php8.4-curl php8.4-mbstring php8.4-xml php8.4-gmp php8.4-common \
    && rm -rf /var/lib/apt/lists/*

# Настройка PHP и Apache.
RUN set -eux; \
    for ini in /etc/php/8.4/apache2/php.ini /etc/php/8.4/cli/php.ini; do \
        if [ -f "$ini" ]; then \
            sed -i -E 's/^extension=(curl|mbstring|openssl|pdo|pdo_mysql|mysqli|mysqlnd|sodium|gmp|gd|zip|xml)$/;extension=\1 ; loaded via conf.d or built-in/' "$ini"; \
            sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$ini"; \
            sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 64M/' "$ini"; \
            sed -i 's/^post_max_size = .*/post_max_size = 64M/' "$ini"; \
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

# acme.sh: штатный --nocron обходит pre-check crontab без заглушек.
RUN set -e; \
    curl -fsSL https://get.acme.sh -o /tmp/acme-bootstrap.sh; \
    head -n1 /tmp/acme-bootstrap.sh | grep -q '^#!/'; \
    sh /tmp/acme-bootstrap.sh email=acme@example.com --nocron; \
    test -x /root/.acme.sh/acme.sh; \
    rm -f /tmp/acme-bootstrap.sh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80 443 7402 3306

ENTRYPOINT ["/entrypoint.sh"]
