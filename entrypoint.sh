#!/bin/bash

# Если этот файл лежит на примонтированном диске, встроенный entrypoint
# передаст ему управление. Эта защита предотвращает повторный вход в себя.
if [ -f /mikrobill-data/entrypoint.sh ] && [ "${MB_ENTRYPOINT_EXTERNAL:-0}" != "1" ]; then
    echo "External entrypoint.sh found on mounted storage - using it"
    export MB_ENTRYPOINT_EXTERNAL=1
    exec bash /mikrobill-data/entrypoint.sh
fi

set -u

# --- Логирование ---
if [ "${MB_LOG_SET:-0}" != "1" ]; then
    export MB_LOG_SET=1
    mkdir -p /mikrobill-data
    exec > >(tee -a "/mikrobill-data/entrypoint.log") 2>&1
fi

echo "=== Entrypoint started at $(date) ==="

# --- Конфигурация ---
CONFDIR="${MB_CONFDIR:-data}"

# confdir должен быть простым именем каталога, не абсолютным путём
case "$CONFDIR" in
    /*|*..*)
        echo "FATAL: MB_CONFDIR must be a simple directory name, got: $CONFDIR"
        exit 1
        ;;
esac

DB_NAME=${DB_NAME:-mikrobill}
DB_USER=${DB_USER:-mikrobill}
ADMIN_LOGIN=${ADMIN_LOGIN:-Admin}

WEB_DIR=/var/www/html
SECRET_DIR=/mikrobill-data/secrets
INSTALL_DIR=/opt/mikrobill-installer

mkdir -p "$SECRET_DIR" "$WEB_DIR" /var/run/mysqld

# --- Проверка внешнего тома ---
is_mounted() {
    mountpoint -q "$1" 2>/dev/null && return 0
    awk -v d="$1" '$2 == d {found=1} END {exit !found}' /proc/mounts 2>/dev/null
}

if ! is_mounted /mikrobill-data; then
    echo "WARNING: /mikrobill-data is not a mount point. Data may not survive container recreation."
fi

# --- Только bind mount, без симлинков ---
bind_dir() {
    local src="$1"
    local dst="$2"

    if [ -L "$dst" ]; then
        echo "Removing symlink: $dst"
        rm -f "$dst"
    fi

    mkdir -p "$src" "$dst"

    if is_mounted "$dst"; then
        echo "Already mounted: $dst"
        return 0
    fi

    if ! mount --bind "$src" "$dst"; then
        echo "FATAL: cannot bind mount $src -> $dst"
        exit 1
    fi

    echo "Bind mounted: $src -> $dst"
}

# --- Старые whole-mounts /var/MikroBILL больше не используются ---
if is_mounted /var/MikroBILL; then
    echo "Old mount detected on /var/MikroBILL, unmounting it"
    umount -R /var/MikroBILL 2>/dev/null || \
    umount /var/MikroBILL 2>/dev/null || \
    umount -l /var/MikroBILL 2>/dev/null || true
fi

# Убираем возможные старые симлинки и создаём реальные каталоги
for p in /var/lib/mysql /var/www/html /var/MikroBILL; do
    if [ -L "$p" ]; then
        echo "Removing symlink: $p"
        rm -f "$p"
    fi
    mkdir -p "$p"
done

# --- Внешние данные ---
bind_dir /mikrobill-data/mysql                 /var/lib/mysql
bind_dir /mikrobill-data/web                   /var/www/html
bind_dir /mikrobill-data/data                  "/var/MikroBILL/${CONFDIR}"
bind_dir /mikrobill-data/data/cert             /var/MikroBILL/cert

chown -R mysql:mysql /var/run/mysqld /var/lib/mysql 2>/dev/null || true
chown -R www-data:www-data "$WEB_DIR" 2>/dev/null || true

# --- Миграция старых секретов из прежней структуры данных ---
for f in db_password admin_password; do
    if [ ! -s "$SECRET_DIR/$f" ] && [ -f "/mikrobill-data/data/secrets/$f" ]; then
        cp "/mikrobill-data/data/secrets/$f" "$SECRET_DIR/$f"
    fi
done

# --- Пароль БД ---
if [ -n "${DB_PASSWORD:-}" ]; then
    printf '%s' "$DB_PASSWORD" > "$SECRET_DIR/db_password"
fi

if [ ! -s "$SECRET_DIR/db_password" ]; then
    openssl rand -hex 16 > "$SECRET_DIR/db_password"
fi

DB_PASSWORD=$(cat "$SECRET_DIR/db_password")
chmod 600 "$SECRET_DIR/db_password"

# --- Пароль админа ---
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

sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

DB_USER_SQL=$(sql_escape "$DB_USER")
DB_PASS_SQL=$(sql_escape "$DB_PASSWORD")
DB_NAME_SQL=$(sql_escape "$DB_NAME")

# --- MariaDB config ---
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
DELETE FROM mysql.user WHERE user = '';
DELETE FROM mysql.user WHERE user = 'PUBLIC';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';

CREATE DATABASE IF NOT EXISTS ${DB_NAME_SQL} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${DB_USER_SQL}'@'%' IDENTIFIED BY '${DB_PASS_SQL}';
ALTER USER '${DB_USER_SQL}'@'%' IDENTIFIED BY '${DB_PASS_SQL}';
GRANT ALL PRIVILEGES ON ${DB_NAME_SQL}.* TO '${DB_USER_SQL}'@'%';
REVOKE FILE ON *.* FROM '${DB_USER_SQL}'@'%';

CREATE USER IF NOT EXISTS '${DB_USER_SQL}'@'localhost' IDENTIFIED BY '${DB_PASS_SQL}';
ALTER USER '${DB_USER_SQL}'@'localhost' IDENTIFIED BY '${DB_PASS_SQL}';
GRANT ALL PRIVILEGES ON ${DB_NAME_SQL}.* TO '${DB_USER_SQL}'@'localhost';
REVOKE FILE ON *.* FROM '${DB_USER_SQL}'@'localhost';

CREATE USER IF NOT EXISTS '${DB_USER_SQL}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS_SQL}';
ALTER USER '${DB_USER_SQL}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS_SQL}';
GRANT ALL PRIVILEGES ON ${DB_NAME_SQL}.* TO '${DB_USER_SQL}'@'127.0.0.1';
REVOKE FILE ON *.* FROM '${DB_USER_SQL}'@'127.0.0.1';

CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '';
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;

FLUSH PRIVILEGES;
SQL

echo "Checking and repairing database tables..."
mysqlcheck -uroot --auto-repair --all-databases 2>/dev/null || true

# --- Apache ---
apachectl start >/dev/null 2>&1

# --- Optional WordPress ---
if [ "${ENABLE_WP:-0}" = "1" ]; then
    WP_SETUP=/opt/wp-setup.sh
    [ -f /mikrobill-data/wp-setup.sh ] && WP_SETUP=/mikrobill-data/wp-setup.sh

    if [ -f "$WP_SETUP" ]; then
        bash "$WP_SETUP" || echo "WARNING: WordPress setup failed; MikroBILL continues."
    else
        echo "WARNING: ENABLE_WP=1 but wp-setup.sh missing."
    fi
fi

# --- Канал версии ---
MB_VERSION="${MB_VERSION:-stable}"

# Сохраняем/восстанавливаем канал
if [ -f /mikrobill-data/data/mb_channel ] && [ ! -f /var/MikroBILL/mb_channel ]; then
    cp /mikrobill-data/data/mb_channel /var/MikroBILL/mb_channel 2>/dev/null || true
fi

INSTALLED_CHANNEL=$(cat /var/MikroBILL/mb_channel 2>/dev/null || echo "unknown")

# --- Нужна ли установка/восстановление ---
NEED_INSTALL=0

if [ ! -f /var/MikroBILL/bin/MikroBILL.dll ]; then
    echo "MikroBILL.dll is missing in /var/MikroBILL/bin"
    NEED_INSTALL=1
fi

if [ ! -f "/var/MikroBILL/${CONFDIR}/MikroBILL.xml" ]; then
    echo "MikroBILL.xml is missing in /var/MikroBILL/${CONFDIR}"
    NEED_INSTALL=1
fi

# --- Подготовка установщика ---
if [ "$NEED_INSTALL" = "1" ]; then
    echo "Install/repair required. Selected MikroBILL version: $MB_VERSION, confdir: $CONFDIR"

    if [ "$MB_VERSION" = "beta" ]; then
        echo "Preparing beta installer..."

        if [ -f /opt/mikrobill-beta.zip ]; then
            echo "Unpacking beta installer from image..."
            rm -rf "$INSTALL_DIR"
            mkdir -p "$INSTALL_DIR"
            unzip -o /opt/mikrobill-beta.zip -d "$INSTALL_DIR" || echo "ERROR: cannot unpack beta archive"
        else
            echo "Beta archive not found in image - downloading fresh copy..."
            mkdir -p "$INSTALL_DIR"

            if wget --no-check-certificate -O /tmp/MikroBILL.zip https://mikro-bill.com/downloads/beta; then
                unzip -o /tmp/MikroBILL.zip -d "$INSTALL_DIR" && rm -f /tmp/MikroBILL.zip
            else
                echo "ERROR: cannot download MikroBILL beta installer"
            fi
        fi
    else
        echo "Preparing stable installer..."

        if [ ! -f "$INSTALL_DIR/MikroBILL.dll" ]; then
            echo "Installer not found in image - downloading fresh copy..."
            mkdir -p "$INSTALL_DIR"

            if wget --no-check-certificate -O /tmp/MikroBILL.zip https://mikro-bill.com/downloads/stable; then
                unzip -o /tmp/MikroBILL.zip -d "$INSTALL_DIR" && rm -f /tmp/MikroBILL.zip
            else
                echo "ERROR: cannot download MikroBILL installer"
            fi
        fi
    fi
else
    echo "MikroBILL already installed (channel: $INSTALLED_CHANNEL, confdir: $CONFDIR)"

    if [ "$INSTALLED_CHANNEL" != "unknown" ] && [ "$INSTALLED_CHANNEL" != "$MB_VERSION" ]; then
        echo "NOTE: MB_VERSION=$MB_VERSION differs from installed channel; channel applies only to a fresh install"
    fi
fi

# --- Silent install / repair ---
if [ "$NEED_INSTALL" = "1" ]; then
    if [ ! -f "$INSTALL_DIR/MikroBILL.dll" ]; then
        echo "FATAL: installer MikroBILL.dll not found"
        exit 1
    fi

    echo "First run or repair: installing MikroBILL ($MB_VERSION) with confdir=${CONFDIR}..."

    CONTAINER_IP="${CONTAINER_IP:-}"

    if [ -z "$CONTAINER_IP" ]; then
        CONTAINER_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

        if [ -z "$CONTAINER_IP" ]; then
            CONTAINER_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
        fi
    fi

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
            web_path: $web_path,
            web_url: $web_url,
            check_db: "0",
            language: "ru",
            db_ip: $db_ip,
            db_port: $db_port,
            db_name: $db_name,
            db_login: $db_login,
            db_pass: $db_pass,
            admin_login: $admin_login,
            admin_pass: $admin_pass,
            admin_allowed_ip: "",
            lic_accept: "1"
        }')

    INSTALL_RC=0

    dotnet "$INSTALL_DIR/MikroBILL.dll" /SILENT_INSTALL="$INSTALL_JSON" /confdir="$CONFDIR" || INSTALL_RC=$?

    echo "Silent install finished with rc=$INSTALL_RC"

    if [ -f /var/MikroBILL/bin/MikroBILL.dll ]; then
        printf '%s' "$MB_VERSION" > /var/MikroBILL/mb_channel
        cp /var/MikroBILL/mb_channel /mikrobill-data/data/mb_channel 2>/dev/null || true
    else
        echo "FATAL: MikroBILL silent install did not produce /var/MikroBILL/bin/MikroBILL.dll"
        exit 1
    fi

    sleep 5
fi

# --- Web-каталоги ---
mkdir -p "$WEB_DIR"/payin "$WEB_DIR"/actionin "$WEB_DIR"/news "$WEB_DIR"/tvin

if [ -d /var/MikroBILL/bin/web ] && [ ! -f "${WEB_DIR}/web.ver" ]; then
    cp -rT /var/MikroBILL/bin/web "${WEB_DIR}" || true
fi

for d in payin actionin news tvin; do
    mkdir -p "${WEB_DIR}/$d"
    chmod -R a=rwx "${WEB_DIR}/$d" 2>/dev/null || true
done

chown -R www-data:www-data "${WEB_DIR}" 2>/dev/null || true

# --- Запуск ядра ---
cd /var/MikroBILL || true

if [ -f /var/MikroBILL/bin/MikroBILL.dll ]; then
    echo "Starting: dotnet /var/MikroBILL/bin/MikroBILL.dll /SERVER /confdir=${CONFDIR}"
    exec dotnet /var/MikroBILL/bin/MikroBILL.dll /SERVER /confdir="$CONFDIR"
else
    echo "FATAL: installed core not found"
    exit 1
fi
