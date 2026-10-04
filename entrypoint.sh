#!/bin/bash
# If a newer entrypoint.sh exists on mounted storage - use it (no image rebuild needed)
if [ -f /mikrobill-data/entrypoint.sh ] && [ "${MB_ENTRYPOINT_EXTERNAL:-0}" != "1" ]; then
    echo "External entrypoint.sh found on mounted storage - using it"
    export MB_ENTRYPOINT_EXTERNAL=1
    exec bash /mikrobill-data/entrypoint.sh
fi
set -u

# --- Магия единой точки монтирования ---
if [ -d "/mikrobill-data" ]; then
    echo "External storage detected. Creating symlinks..."
    mkdir -p /mikrobill-data/mysql /mikrobill-data/data /mikrobill-data/web
    
    # Удаляем пустые папки, созданные при сборке образа, чтобы заменить их симлинками
    for target in /var/lib/mysql /var/MikroBILL /var/www/html; do
        if [ -d "$target" ] && [ ! -L "$target" ]; then
            rm -rf "$target"
        fi
    done
    
    # Создаем симлинки на внешнее хранилище
    ln -sfn /mikrobill-data/mysql /var/lib/mysql
    ln -sfn /mikrobill-data/data /var/MikroBILL
    ln -sfn /mikrobill-data/web /var/www/html
fi

DB_NAME=${DB_NAME:-mikrobill}
DB_USER=${DB_USER:-mikrobill}
ADMIN_LOGIN=${ADMIN_LOGIN:-admin}

WEB_DIR=/var/www/html
SECRET_DIR=/var/MikroBILL/secrets

mkdir -p "$SECRET_DIR" "$WEB_DIR" /var/run/mysqld
chown -R mysql:mysql /var/run/mysqld /var/lib/mysql 2>/dev/null || true
chown -R www-data:www-data "$WEB_DIR" 2>/dev/null || true

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

# --- Запуск cron (КРИТИЧНО для встроенного в MikroBILL acme.sh) ---
cron || true

# --- Запуск Apache (нужен для ACME HTTP-01 challenge и работы WEB) ---
apachectl start >/dev/null 2>&1 || service apache2 start

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
