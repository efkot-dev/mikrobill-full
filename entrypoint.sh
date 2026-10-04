#!/bin/bash
set -u

DB_NAME=${DB_NAME:-mikrobill}
DB_USER=${DB_USER:-mikrobill}
ADMIN_LOGIN=${ADMIN_LOGIN:-admin}

WEB_DIR=/var/www/html
ACME_WEBROOT=/var/www/letsencrypt
SECRET_DIR=/var/MikroBILL/secrets
CERT_DIR=/var/MikroBILL/cert
ACME_BIN=${ACME_BIN:-/root/.acme.sh/acme.sh}

mkdir -p "$SECRET_DIR" "$CERT_DIR" "$WEB_DIR" "$ACME_WEBROOT/.well-known/acme-challenge" /var/run/mysqld
chown -R mysql:mysql /var/run/mysqld /var/lib/mysql 2>/dev/null || true
chown -R www-data:www-data "$WEB_DIR" "$ACME_WEBROOT" 2>/dev/null || true

# --- Пароль БД ---
if [ -n "${DB_PASSWORD:-}" ]; then
    printf '%s' "$DB_PASSWORD" > "$SECRET_DIR/db_password"
fi
if [ ! -s "$SECRET_DIR/db_password" ]; then
    openssl rand -hex 16 > "$SECRET_DIR/db_password"
fi
DB_PASSWORD=$(cat "$SECRET_DIR/db_password")
chmod 600 "$SECRET_DIR/db_password"

# --- Пароль администратора MikroBILL ---
if [ -n "${ADMIN_PASSWORD:-}" ]; then
    printf '%s' "$ADMIN_PASSWORD" > "$SECRET_DIR/admin_password"
fi
if [ ! -s "$SECRET_DIR/admin_password" ]; then
    openssl rand -hex 12 > "$SECRET_DIR/admin_password"
fi
ADMIN_PASSWORD=$(cat "$SECRET_DIR/admin_password")
chmod 600 "$SECRET_DIR/admin_password"

echo "DB password file: /var/MikroBILL/secrets/db_password"
echo "Admin password file: /var/MikroBILL/secrets/admin_password"

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
DB_USER_SQL=$(sql_escape "$DB_USER")
DB_PASS_SQL=$(sql_escape "$DB_PASSWORD")
DB_NAME_SQL=$(sql_escape "$DB_NAME")

# --- Инициализация и запуск MariaDB ---
if [ ! -d /var/lib/mysql/mysql ]; then
    echo "Initializing MariaDB..."
    if command -v mariadb-install-db >/dev/null 2>&1; then
        mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null
    else
        mysql_install_db --user=mysql --datadir=/var/lib/mysql >/dev/null
    fi
fi

mysqld_safe --skip-syslog &

for i in $(seq 1 30); do
    mysqladmin ping --silent 2>/dev/null && break
    sleep 2
done

mysql -uroot <<SQL || true
CREATE DATABASE IF NOT EXISTS ${DB_NAME_SQL} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER_SQL}'@'localhost' IDENTIFIED BY '${DB_PASS_SQL}';
CREATE USER IF NOT EXISTS '${DB_USER_SQL}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS_SQL}';
GRANT ALL PRIVILEGES ON ${DB_NAME_SQL}.* TO '${DB_USER_SQL}'@'localhost';
GRANT ALL PRIVILEGES ON ${DB_NAME_SQL}.* TO '${DB_USER_SQL}'@'127.0.0.1';
REVOKE FILE ON *.* FROM '${DB_USER_SQL}'@'localhost';
REVOKE FILE ON *.* FROM '${DB_USER_SQL}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# --- cron для продления ACME ---
cron || true
apachectl start >/dev/null 2>&1 || service apache2 start

# --- ACMEv2 ---
if [ -n "${ACME_DOMAIN:-}" ]; then
    if [ ! -x "$ACME_BIN" ]; then
        curl -fsSL https://get.acme.sh | sh -s email="${ACME_EMAIL:-admin@example.com}" || true
    fi

    if [ -x "$ACME_BIN" ]; then
        ACME_EXTRA_ARGS=""
        if [ "${ACME_STAGING:-no}" = "yes" ]; then ACME_EXTRA_ARGS="--staging"; fi

        if [ ! -f "$CERT_DIR/${ACME_DOMAIN}.crt" ] || [ "${ACME_FORCE:-no}" = "yes" ]; then
            if [ -n "${ACME_DNS:-}" ]; then
                "$ACME_BIN" --issue -d "$ACME_DOMAIN" --dns "$ACME_DNS" --keylength 2048 $ACME_EXTRA_ARGS || true
            else
                "$ACME_BIN" --issue -d "$ACME_DOMAIN" -w "$ACME_WEBROOT" --keylength 2048 $ACME_EXTRA_ARGS || true
            fi
        fi

        "$ACME_BIN" --install-cert \
            -d "$ACME_DOMAIN" \
            --key-file "$CERT_DIR/${ACME_DOMAIN}.key" \
            --fullchain-file "$CERT_DIR/${ACME_DOMAIN}.crt" \
            --reloadcmd "apachectl graceful >/dev/null 2>&1 || service apache2 reload" || true

        if [ -f "$CERT_DIR/${ACME_DOMAIN}.crt" ]; then
            cat > /etc/apache2/sites-available/mikrobill-ssl.conf <<EOF
<VirtualHost *:443>
    ServerName ${ACME_DOMAIN}
    DocumentRoot ${WEB_DIR}
    SSLEngine on
    SSLCertificateFile ${CERT_DIR}/${ACME_DOMAIN}.crt
    SSLCertificateKeyFile ${CERT_DIR}/${ACME_DOMAIN}.key
    <Directory ${WEB_DIR}>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
            a2enmod ssl >/dev/null 2>&1 || true
            a2ensite mikrobill-ssl >/dev/null 2>&1 || true
            apachectl graceful >/dev/null 2>&1 || true
        fi
    fi
fi

# --- Установка MikroBILL ---
if [ ! -f /var/MikroBILL/MikroBILL.xml ]; then
    echo "First run: installing MikroBILL..."
    INSTALL_JSON=$(jq -c -n \
        --arg web_path "$WEB_DIR" \
        --arg db_ip "localhost" \
        --arg db_port "3306" \
        --arg db_name "$DB_NAME" \
        --arg db_login "$DB_USER" \
        --arg db_pass "$DB_PASSWORD" \
        --arg admin_login "$ADMIN_LOGIN" \
        --arg admin_pass "$ADMIN_PASSWORD" \
        '{
            web_path: $web_path, check_db: "0", language: "ru",
            db_ip: $db_ip, db_port: $db_port, db_name: $db_name,
            db_login: $db_login, db_pass: $db_pass,
            admin_login: $admin_login, admin_pass: $admin_pass,
            admin_allowed_ip: "", lic_accept: "1"
        }')

    dotnet /opt/mikrobill-installer/MikroBILL.dll /SILENT_INSTALL="$INSTALL_JSON" || echo "MikroBILL silent install failed"
    sleep 5
fi

# --- WEB-файлы и права ---
if [ -d /var/MikroBILL/bin/web ] && [ ! -f "${WEB_DIR}/web.ver" ]; then
    cp -rT /var/MikroBILL/bin/web "${WEB_DIR}" || true
fi

for d in payin actionin news tvin; do
    mkdir -p "${WEB_DIR}/$d"
    chmod -R a=rwx "${WEB_DIR}/$d"
done

chown -R www-data:www-data "${WEB_DIR}" 2>/dev/null || true

# --- Запуск ядра MikroBILL ---
if [ -f /var/MikroBILL/bin/MikroBILL.dll ]; then
    exec dotnet /var/MikroBILL/bin/MikroBILL.dll /SERVER
else
    exec dotnet /opt/mikrobill-installer/MikroBILL.dll /SERVER
fi
