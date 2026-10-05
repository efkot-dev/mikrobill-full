#!/bin/bash
# If a newer copy of this script lies on the mounted storage, the baked-in
# /entrypoint.sh hands control over to it. Guard prevents a self-exec loop.
if [ -f /mikrobill-data/entrypoint.sh ] && [ "${MB_ENTRYPOINT_EXTERNAL:-0}" != "1" ]; then
    echo "External entrypoint.sh found on mounted storage - using it"
    export MB_ENTRYPOINT_EXTERNAL=1
    exec bash /mikrobill-data/entrypoint.sh
fi
set -u

# RouterOS may leave loopback down inside containers
if ! ip link show lo 2>/dev/null | grep -q "UP"; then
    ip addr add 127.0.0.1/8 dev lo 2>/dev/null || true
    ip link set lo up 2>/dev/null || true
    echo "loopback interface brought up"
fi

# --- Single mount point: spread it over the standard paths ---
if [ -d "/mikrobill-data" ]; then
    echo "External storage detected. Creating symlinks..."
    mkdir -p /mikrobill-data/mysql /mikrobill-data/data /mikrobill-data/web
    for target in /var/lib/mysql /var/MikroBILL /var/www/html; do
        if [ -d "$target" ] && [ ! -L "$target" ]; then
            rm -rf "$target"
        fi
    done
    ln -sfn /mikrobill-data/mysql /var/lib/mysql
    ln -sfn /mikrobill-data/data /var/MikroBILL
    ln -sfn /mikrobill-data/web /var/www/html
fi

DB_NAME=${DB_NAME:-mikrobill}
DB_USER=${DB_USER:-mikrobill}
ADMIN_LOGIN=${ADMIN_LOGIN:-Admin}

WEB_DIR=/var/www/html
SECRET_DIR=/mikrobill-data/secrets
INSTALL_DIR=/opt/mikrobill-installer

mkdir -p "$SECRET_DIR" "$WEB_DIR" /var/run/mysqld

# Migration from the old secrets location (<mount>/data/secrets)
for f in db_password admin_password; do
    if [ ! -s "$SECRET_DIR/$f" ] && [ -f /var/MikroBILL/secrets/$f ]; then
        cp /var/MikroBILL/secrets/$f "$SECRET_DIR/$f"
    fi
done

chown -R mysql:mysql /var/run/mysqld /var/lib/mysql 2>/dev/null || true
chown -R www-data:www-data "$WEB_DIR" 2>/dev/null || true

# --- DB password (env or auto-generate into the mounted secrets dir) ---
if [ -n "${DB_PASSWORD:-}" ]; then
    printf '%s' "$DB_PASSWORD" > "$SECRET_DIR/db_password"
fi
if [ ! -s "$SECRET_DIR/db_password" ]; then
    openssl rand -hex 16 > "$SECRET_DIR/db_password"
fi
DB_PASSWORD=$(cat "$SECRET_DIR/db_password")
chmod 600 "$SECRET_DIR/db_password"

# --- Admin password (env or auto-generate) ---
if [ -n "${ADMIN_PASSWORD:-}" ]; then
    printf '%s' "$ADMIN_PASSWORD" > "$SECRET_DIR/admin_password"
fi
if [ ! -s "$SECRET_DIR/admin_password" ]; then
    openssl rand -hex 12 > "$SECRET_DIR/admin_password"
fi
ADMIN_PASSWORD=$(cat "$SECRET_DIR/admin_password")
chmod 600 "$SECRET_DIR/admin_password"

echo "DB password file: $SECRET_DIR/db_password"
echo "Admin password file: $SECRET_DIR/admin_password"

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
DB_USER_SQL=$(sql_escape "$DB_USER")
DB_PASS_SQL=$(sql_escape "$DB_PASSWORD")
DB_NAME_SQL=$(sql_escape "$DB_NAME")

# --- MariaDB init & start ---
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
CREATE USER IF NOT EXISTS '${DB_USER_SQL}'@'%' IDENTIFIED BY '${DB_PASS_SQL}';
GRANT ALL PRIVILEGES ON ${DB_NAME_SQL}.* TO '${DB_USER_SQL}'@'%';
ALTER USER '${DB_USER_SQL}'@'%' IDENTIFIED BY '${DB_PASS_SQL}';
REVOKE FILE ON *.* FROM '${DB_USER_SQL}'@'%';
FLUSH PRIVILEGES;
SQL

# --- cron (acme.sh renewals) & Apache (web + ACME HTTP-01) ---
cron || true
apachectl start >/dev/null 2>&1 || service apache2 start

# --- Installer self-heal: image may lack it ---
if [ ! -f "$INSTALL_DIR/MikroBILL.dll" ]; then
    echo "Installer not found in image - downloading fresh copy..."
    mkdir -p "$INSTALL_DIR"
    if wget --no-check-certificate -O /tmp/MikroBILL.zip https://mikro-bill.com/downloads/stable; then
        unzip -o /tmp/MikroBILL.zip -d "$INSTALL_DIR" && rm -f /tmp/MikroBILL.zip
    else
        echo "ERROR: cannot download MikroBILL installer"
    fi
fi

# --- Silent install on first run ---
if [ ! -f /var/MikroBILL/MikroBILL.xml ]; then
    echo "First run: installing MikroBILL..."
    INSTALL_JSON=$(jq -c -n \
        --arg web_path "$WEB_DIR" \
        --arg db_ip "127.0.0.1" \
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
    dotnet "$INSTALL_DIR/MikroBILL.dll" /SILENT_INSTALL="$INSTALL_JSON" || echo "MikroBILL silent install failed"
    sleep 5
fi

# --- Web files & permissions (official instruction) ---
if [ -d /var/MikroBILL/bin/web ] && [ ! -f "${WEB_DIR}/web.ver" ]; then
    cp -rT /var/MikroBILL/bin/web "${WEB_DIR}" || true
fi
for d in payin actionin news tvin; do
    mkdir -p "${WEB_DIR}/$d"
    chmod -R a=rwx "${WEB_DIR}/$d"
done
chown -R www-data:www-data "${WEB_DIR}" 2>/dev/null || true

# --- Start core ---
if [ -f /var/MikroBILL/bin/MikroBILL.dll ]; then
    exec dotnet /var/MikroBILL/bin/MikroBILL.dll /SERVER
elif [ -f "$INSTALL_DIR/MikroBILL.dll" ] && [ -f /var/MikroBILL/MikroBILL.xml ]; then
    exec dotnet "$INSTALL_DIR/MikroBILL.dll" /SERVER
else
    echo "FATAL: installed core not found and silent install did not produce it"
    exit 1
fi
