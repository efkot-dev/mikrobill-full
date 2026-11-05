#!/bin/bash
# If a newer copy of this script lies on the mounted storage, the baked-in
# /entrypoint.sh hands control over to it. Guard prevents a self-exec loop.
if [ -f /mikrobill-data/entrypoint.sh ] && [ "${MB_ENTRYPOINT_EXTERNAL:-0}" != "1" ]; then
    echo "External entrypoint.sh found on mounted storage - using it"
    export MB_ENTRYPOINT_EXTERNAL=1
    exec bash /mikrobill-data/entrypoint.sh
fi
set -u

# --- Logging: strict one-time tee (prevents duplicate lines) ---
if [ "${MB_LOG_SET:-0}" != "1" ]; then
    export MB_LOG_SET=1
    exec > >(tee -a "/mikrobill-data/entrypoint.log") 2>&1
fi

echo "=== Entrypoint started at $(date) ==="

# --- systemctl shim: container has no systemd, but installer calls it ---
if [ ! -x /usr/local/bin/systemctl ]; then
    printf '#!/bin/sh\n# container shim: no systemd inside\nexit 0\n' > /usr/local/bin/systemctl
    chmod +x /usr/local/bin/systemctl
fi

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

# --- MariaDB config: bind to all interfaces, skip log-bin, skip name resolve ---
CNF=/etc/mysql/mariadb.conf.d/50-server.cnf
if [ -f "$CNF" ] && ! grep -q '^skip-name-resolve' "$CNF"; then
    sed -i 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' "$CNF"
    sed -i '/^\[mysqld\]/a skip-log-bin\nskip-name-resolve' "$CNF"
fi

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
-- Очистка анонимных пользователей во избежание конфликтов прав
DELETE FROM mysql.user WHERE user = '';

-- Создание базы данных
CREATE DATABASE IF NOT EXISTS ${DB_NAME_SQL} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Создание и обновление прав для сетевого доступа (%)
CREATE USER IF NOT EXISTS '${DB_USER_SQL}'@'%' IDENTIFIED BY '${DB_PASS_SQL}';
ALTER USER '${DB_USER_SQL}'@'%' IDENTIFIED BY '${DB_PASS_SQL}';
GRANT ALL PRIVILEGES ON ${DB_NAME_SQL}.* TO '${DB_USER_SQL}'@'%';
REVOKE FILE ON *.* FROM '${DB_USER_SQL}'@'%';

-- Создание и обновление прав для локального сокета (localhost)
CREATE USER IF NOT EXISTS '${DB_USER_SQL}'@'localhost' IDENTIFIED BY '${DB_PASS_SQL}';
ALTER USER '${DB_USER_SQL}'@'localhost' IDENTIFIED BY '${DB_PASS_SQL}';
GRANT ALL PRIVILEGES ON ${DB_NAME_SQL}.* TO '${DB_USER_SQL}'@'localhost';
REVOKE FILE ON *.* FROM '${DB_USER_SQL}'@'localhost';

-- Создание и обновление прав для локального IP (127.0.0.1)
CREATE USER IF NOT EXISTS '${DB_USER_SQL}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS_SQL}';
ALTER USER '${DB_USER_SQL}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS_SQL}';
GRANT ALL PRIVILEGES ON ${DB_NAME_SQL}.* TO '${DB_USER_SQL}'@'127.0.0.1';
REVOKE FILE ON *.* FROM '${DB_USER_SQL}'@'127.0.0.1';

FLUSH PRIVILEGES;
SQL

# --- Auto-repair crashed tables (MyISAM tables can crash on unclean shutdown) ---
echo "Checking and repairing database tables..."
mysqlcheck -uroot --auto-repair --all-databases 2>/dev/null || true

# --- Apache (web + ACME HTTP-01) ---
apachectl start >/dev/null 2>&1

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

# --- Pre-create directories that installer chmod's before creating ---
mkdir -p "$WEB_DIR"/payin "$WEB_DIR"/actionin "$WEB_DIR"/news "$WEB_DIR"/tvin

# --- Silent install on first run ---
if [ ! -f /var/MikroBILL/MikroBILL.xml ]; then
    echo "First run: installing MikroBILL..."
    
    # Determine container IP for web_url (from ENV or auto-detect)
    CONTAINER_IP="${CONTAINER_IP:-}"
    if [ -z "$CONTAINER_IP" ]; then
        # Auto-detect: get IP of eth0 (veth interface inside container)
        CONTAINER_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        if [ -z "$CONTAINER_IP" ]; then
            # Fallback: use hostname -i
            CONTAINER_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
        fi
    fi
    
    # Build web_url (allow override via ENV)
    WEB_URL="${WEB_URL:-http://${CONTAINER_IP}}"
    echo "Container IP: $CONTAINER_IP"
    echo "Web URL: $WEB_URL"
    
    INSTALL_JSON=$(jq -c -n \
        --arg web_path "$WEB_DIR" \
        --arg web_url "$WEB_URL" \
        --arg db_ip "127.0.0.1" \
        --arg db_port "3306" \
        --arg db_name "$DB_NAME" \
        --arg db_login "$DB_USER" \
        --arg db_pass "$DB_PASSWORD" \
        --arg admin_login "$ADMIN_LOGIN" \
        --arg admin_pass "$ADMIN_PASSWORD" \
        '{
            web_path: $web_path, web_url: $web_url, check_db: "0", language: "ru",
            db_ip: $db_ip, db_port: $db_port, db_name: $db_name,
            db_login: $db_login, db_pass: $db_pass,
            admin_login: $admin_login, admin_pass: $admin_pass,
            admin_allowed_ip: "", lic_accept: "1"
        }')
    
    INSTALL_RC=0
    dotnet "$INSTALL_DIR/MikroBILL.dll" /SILENT_INSTALL="$INSTALL_JSON" || INSTALL_RC=$?
    if [ -f /var/MikroBILL/MikroBILL.xml ] && [ -f /var/MikroBILL/bin/MikroBILL.dll ]; then
        echo "Silent install finished (rc=$INSTALL_RC), artifacts present - continuing"
    else
        echo "MikroBILL silent install FAILED (rc=$INSTALL_RC), artifacts missing"
    fi
    sleep 5
fi

# --- Web files & permissions (official instruction) ---
if [ -d /var/MikroBILL/bin/web ] && [ ! -f "${WEB_DIR}/web.ver" ]; then
    cp -rT /var/MikroBILL/bin/web "${WEB_DIR}" || true
fi
for d in payin actionin news tvin; do
    mkdir -p "${WEB_DIR}/$d"
    chmod -R a=rwx "${WEB_DIR}/$d" 2>/dev/null || true
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
