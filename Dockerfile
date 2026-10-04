FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    DOTNET_ROOT=/usr/share/dotnet \
    PATH=/usr/share/dotnet:$PATH \
    LANG=C.UTF-8

# Базовые пакеты, MariaDB, Apache, PHP, ACME-зависимости
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget unzip gnupg lsb-release jq openssl socat cron \
    libicu-dev \
    mariadb-server mariadb-client \
    apache2 \
    php php-cli libapache2-mod-php \
    php-mysql php-curl php-mbstring php-xml php-gmp php-common \
    && rm -rf /var/lib/apt/lists/*

# Настройка PHP и Apache (официальная инструкция)
RUN set -eux; \
    for ini in /etc/php/*/apache2/php.ini /etc/php/*/cli/php.ini; do \
        if [ -f "$ini" ]; then \
            sed -i -E 's/^;(extension=(curl|mbstring|openssl|pdo_mysql|sodium|gmp))/\1/' "$ini" || true; \
        fi; \
    done; \
    for ver in /etc/php/*; do \
        v=$(basename "$ver"); \
        if [ -d "$ver" ]; then a2enmod "php$v" 2>/dev/null || true; fi; \
    done; \
    a2enmod rewrite ssl headers; \
    sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf; \
    echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf; \
    a2enconf servername; \
    echo "Alias /.well-known/acme-challenge /var/www/letsencrypt/.well-known/acme-challenge\n<Directory /var/www/letsencrypt/.well-known/acme-challenge>\n    Options -Indexes\n    AllowOverride None\n    Require all granted\n</Directory>" > /etc/apache2/conf-available/acme.conf && \
    a2enconf acme; \
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

# acme.sh для ACMEv2 / Let's Encrypt
RUN curl -fsSL https://get.acme.sh | sh -s email=acme@example.com

# Копируем архив, который заранее скачал GitHub Actions
COPY stable.zip /tmp/stable.zip

# Распаковываем установщик
RUN mkdir -p /opt/mikrobill-installer && \
    unzip -o /tmp/stable.zip -d /opt/mikrobill-installer && \
    rm /tmp/stable.zip

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80 443 7402 7403 7404 7405

ENTRYPOINT ["/entrypoint.sh"]
