#!/bin/bash

# ==============================================================================
# 05-web.sh
#
# Веб-модуль контейнера MikroBILL.
#
# Блоки:
# 01. Запуск Apache.
# 02. Если ENABLE_WP != 1, модуль завершается.
# 03. Переменные WordPress и пути.
# 04. Служебные функции: логирование, WPCLI, секреты, SQL.
# 05. Создание БД WordPress.
# 06. Функции установки/обновления WordPress.
# 07. Apache vhost для отдельного домена WordPress.
# 08. Основной сценарий: first install / upgrade / maintain.
#
# Модуль самодостаточный:
# - не использует внешний wp-setup.sh;
# - не скачивает скрипты во время работы;
# - работает с offline-бандлом /opt/wp-installers из Docker-образа.
# ==============================================================================

# ------------------------------------------------------------------------------
# 01. Запуск Apache.
# ------------------------------------------------------------------------------
apachectl start >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 02. WordPress включается только явно.
# ------------------------------------------------------------------------------
if [ "${ENABLE_WP:-0}" != "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# ------------------------------------------------------------------------------
# 03. Пути и переменные WordPress.
#
# WP_INSTALLERS:
#   Каталог с offline-архивами WordPress, темами, плагинами и mu-plugin.
#   По умолчанию берется из образа: /opt/wp-installers.
#   Если на диске есть /mikrobill-data/wp-installers, он имеет приоритет.
#
# WP_DATA:
#   Постоянное хранилище метаданных WordPress на внешнем диске.
#
# WP_DIR:
#   Реальный document root WordPress внутри контейнера.
#   Так как /var/www/html bind-монтируется из /mikrobill-data/web,
#   /var/www/html/wp физически лежит в /mikrobill-data/web/wp.
# ------------------------------------------------------------------------------
WP_INSTALLERS="${WP_INSTALLERS:-/opt/wp-installers}"

if [ ! -d "$WP_INSTALLERS" ] && [ -d "/mikrobill-data/wp-installers" ]; then
    WP_INSTALLERS="/mikrobill-data/wp-installers"
fi

WP_DATA="${WP_DATA:-/mikrobill-data/web/wp}"
WP_DIR="${WP_DIR:-/var/www/html/wp}"

WP_DB_NAME="${WP_DB_NAME:-${DB_NAME:-mikrobill}_wp}"
WP_DB_USER="${WP_DB_USER:-${DB_USER:-mikrobill}_wp}"

WP_ADMIN_USER="${WP_ADMIN_USER:-wpadmin}"
WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-admin@localhost}"
WP_TITLE="${WP_TITLE:-MikroBILL Site}"

WP_DOMAIN="${WP_DOMAIN:-}"
WP_ALIAS="${WP_ALIAS:-}"
WP_SCHEME="${WP_SCHEME:-}"
WP_BASE_URL="${WP_BASE_URL:-}"

mkdir -p "$WP_DATA" "$WP_DIR" "$SECRET_DIR" /var/www/html

# ------------------------------------------------------------------------------
# Определяем схему и базовый URL WordPress.
#
# Если задан WP_DOMAIN:
#   WP_BASE_URL = http(s)://WP_DOMAIN
#
# Если домен не задан:
#   WP_BASE_URL = WEB_URL/wp
#   например http://10.0.10.104/wp
# ------------------------------------------------------------------------------
if [ -z "$WP_SCHEME" ]; then
    case "${WEB_URL:-}" in
        https://*)
            WP_SCHEME="https"
            ;;
        *)
            WP_SCHEME="http"
            ;;
    esac
fi

if [ -z "$WP_BASE_URL" ]; then
    if [ -n "$WP_DOMAIN" ]; then
        WP_BASE_URL="${WP_SCHEME}://${WP_DOMAIN}"
    else
        WP_BASE_ROOT="${WEB_URL:-http://${CONTAINER_IP:-127.0.0.1}}"
        WP_BASE_URL="${WP_BASE_ROOT%/}/wp"
    fi
fi

# ------------------------------------------------------------------------------
# 04. Служебные функции.
# ------------------------------------------------------------------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [wp] $*"
}

err() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [wp][error] $*" >&2
}

# Если общий sql_escape уже подключен из 00-common.sh, не переопределяем.
if ! declare -F sql_escape >/dev/null 2>&1; then
    sql_escape() {
        printf '%s' "$1" | sed "s/'/''/g"
    }
fi

WPCLI() {
    wp --allow-root --path="$WP_DIR" "$@"
}

wp_check_required_binaries() {
    local missing=0

    if ! command -v wp >/dev/null 2>&1; then
        err "wp-cli not found"
        missing=1
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        err "unzip not found"
        missing=1
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        err "openssl not found"
        missing=1
    fi

    if ! command -v mysql >/dev/null 2>&1; then
        err "mysql client not found"
        missing=1
    fi

    return "$missing"
}

wp_check_installer_bundle() {
    if [ ! -d "$WP_INSTALLERS" ]; then
        err "WordPress installer directory not found: $WP_INSTALLERS"
        return 1
    fi

    if [ ! -f "$WP_INSTALLERS/wordpress-ru_RU.zip" ]; then
        err "WordPress core archive not found: $WP_INSTALLERS/wordpress-ru_RU.zip"
        return 1
    fi

    return 0
}

# ------------------------------------------------------------------------------
# Секреты WordPress.
#
# Если переменная задана снаружи — записываем ее в файл секрета.
# Если файла нет — генерируем.
# Всегда читаем финальное значение из файла, чтобы пароль пережил рестарт.
# ------------------------------------------------------------------------------
if [ -n "${WP_DB_PASS:-}" ]; then
    printf '%s' "$WP_DB_PASS" > "$SECRET_DIR/wp_db_password"
fi

if [ ! -s "$SECRET_DIR/wp_db_password" ]; then
    openssl rand -hex 16 > "$SECRET_DIR/wp_db_password"
fi

WP_DB_PASS=$(cat "$SECRET_DIR/wp_db_password")
chmod 600 "$SECRET_DIR/wp_db_password"

if [ -n "${WP_ADMIN_PASS:-}" ]; then
    printf '%s' "$WP_ADMIN_PASS" > "$SECRET_DIR/wp_admin_password"
fi

if [ ! -s "$SECRET_DIR/wp_admin_password" ]; then
    openssl rand -hex 12 > "$SECRET_DIR/wp_admin_password"
fi

WP_ADMIN_PASS=$(cat "$SECRET_DIR/wp_admin_password")
chmod 600 "$SECRET_DIR/wp_admin_password"

# ------------------------------------------------------------------------------
# 05. Создание базы данных WordPress.
# ------------------------------------------------------------------------------
wp_ensure_database() {
    local db_name_sql db_user_sql db_pass_sql

    db_name_sql=$(sql_escape "$WP_DB_NAME")
    db_user_sql=$(sql_escape "$WP_DB_USER")
    db_pass_sql=$(sql_escape "$WP_DB_PASS")

    mysql -uroot <<SQL || {
        err "Cannot create WordPress database/user"
        return 1
    }
CREATE DATABASE IF NOT EXISTS ${db_name_sql} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${db_user_sql}'@'localhost' IDENTIFIED BY '${db_pass_sql}';
ALTER USER '${db_user_sql}'@'localhost' IDENTIFIED BY '${db_pass_sql}';
GRANT ALL PRIVILEGES ON ${db_name_sql}.* TO '${db_user_sql}'@'localhost';

CREATE USER IF NOT EXISTS '${db_user_sql}'@'127.0.0.1' IDENTIFIED BY '${db_pass_sql}';
ALTER USER '${db_user_sql}'@'127.0.0.1' IDENTIFIED BY '${db_pass_sql}';
GRANT ALL PRIVILEGES ON ${db_name_sql}.* TO '${db_user_sql}'@'127.0.0.1';

FLUSH PRIVILEGES;
SQL

    return 0
}

# ------------------------------------------------------------------------------
# Hash текущего WP-bundle.
#
# Используется для понимания, нужно ли оффлайн-обновление WordPress.
# ------------------------------------------------------------------------------
wp_bundle_hash() {
    if [ -f "$WP_INSTALLERS/BUNDLE_HASH" ]; then
        cat "$WP_INSTALLERS/BUNDLE_HASH"
        return 0
    fi

    if [ -f "$WP_INSTALLERS/manifest.json" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.bundle_hash // "unknown"' "$WP_INSTALLERS/manifest.json"
        return 0
    fi

    echo "unknown"
}

# ------------------------------------------------------------------------------
# Дополнительные PHP-константы в wp-config.php.
# ------------------------------------------------------------------------------
build_extra_php() {
    cat <<'PHP'
define('FS_METHOD', 'direct');
define('AUTOMATIC_UPDATER_DISABLED', true);
define('WP_AUTO_UPDATE_CORE', false);
define('DISALLOW_FILE_EDIT', true);
PHP
}

# ------------------------------------------------------------------------------
# 06. Функции WordPress.
# ------------------------------------------------------------------------------
ensure_page() {
    local slug="$1"
    local title="$2"
    local content="$3"
    local id

    id=$(WPCLI post list --post_type=page --name="$slug" --field=ID 2>/dev/null | head -1)

    if [ -z "$id" ]; then
        id=$(WPCLI post create \
            --post_type=page \
            --post_status=publish \
            --post_title="$title" \
            --post_name="$slug" \
            --post_content="$content" \
            --porcelain)
    fi

    printf '%s' "$id"
}

wp_create_pages() {
    local home_id

    home_id=$(ensure_page home "Главная" "Добро пожаловать на сайт оператора связи. Отредактируйте эту страницу в админке.")

    ensure_page tariffs "Тарифы" "Здесь разместите описание тарифов." >/dev/null
    ensure_page contacts "Контакты" "Телефон, e-mail, адрес и форму обратной связи добавьте здесь." >/dev/null
    ensure_page privacy "Политика обработки персональных данных" "Разместите текст политики обработки персональных данных." >/dev/null

    if [ -n "$home_id" ]; then
        WPCLI option update show_on_front page >/dev/null
        WPCLI option update page_on_front "$home_id" >/dev/null
    fi
}

wp_disable_autoupdates() {
    local p

    for p in $(WPCLI plugin list --field=name 2>/dev/null); do
        WPCLI plugin auto-updates disable "$p" >/dev/null 2>&1 || true
    done

    for p in $(WPCLI theme list --field=name 2>/dev/null); do
        WPCLI theme auto-updates disable "$p" >/dev/null 2>&1 || true
    done
}

wp_install_plugins() {
    if [ -f "$WP_INSTALLERS/kadence.zip" ]; then
        WPCLI theme install "$WP_INSTALLERS/kadence.zip" --activate --force || {
            err "Theme install failed: kadence"
            return 1
        }
    else
        err "Theme archive not found: $WP_INSTALLERS/kadence.zip"
        return 1
    fi

    local p
    for p in kadence-blocks fluentform fluent-smtp limit-login-attempts-reloaded updraftplus; do
        if [ -f "$WP_INSTALLERS/$p.zip" ]; then
            WPCLI plugin install "$WP_INSTALLERS/$p.zip" --activate --force || {
                err "Plugin install failed: $p"
                return 1
            }
        else
            err "Plugin archive not found: $WP_INSTALLERS/$p.zip"
            return 1
        fi
    done

    mkdir -p "$WP_DIR/wp-content/mu-plugins"

    if [ -f "$WP_INSTALLERS/mu-plugins/mikrobill-guard.php" ]; then
        cp -f "$WP_INSTALLERS/mu-plugins/mikrobill-guard.php" \
            "$WP_DIR/wp-content/mu-plugins/mikrobill-guard.php" || {
            err "Cannot install mu-plugin: mikrobill-guard.php"
            return 1
        }
    else
        err "mu-plugin not found: $WP_INSTALLERS/mu-plugins/mikrobill-guard.php"
        return 1
    fi

    return 0
}

wp_write_htaccess() {
    cat > "$WP_DIR/.htaccess" <<'EOF'
# BEGIN WordPress
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
# END WordPress
EOF

    chown www-data:www-data "$WP_DIR/.htaccess" 2>/dev/null || true
    chmod 644 "$WP_DIR/.htaccess"
}

wp_first_install() {
    log "First run: installing WordPress offline (base=$WP_BASE_URL)..."

    rm -rf /tmp/wp-core
    mkdir -p /tmp/wp-core

    unzip -qo "$WP_INSTALLERS/wordpress-ru_RU.zip" -d /tmp/wp-core || {
        err "core unzip failed"
        return 1
    }

    cp -a /tmp/wp-core/wordpress/. "$WP_DIR/" || {
        err "cannot copy WordPress core to $WP_DIR"
        return 1
    }

    rm -rf /tmp/wp-core

    local prefix extra

    prefix="mbwp_$(openssl rand -hex 3)_"
    extra=$(build_extra_php)

    WPCLI config create \
        --dbname="$WP_DB_NAME" \
        --dbuser="$WP_DB_USER" \
        --dbpass="$WP_DB_PASS" \
        --dbhost=localhost \
        --dbcharset=utf8mb4 \
        --dbcollate=utf8mb4_unicode_ci \
        --dbprefix="$prefix" \
        --skip-salts \
        --extra-php="$extra" \
        --force || {
        err "config create failed"
        return 1
    }

    WPCLI core install \
        --url="$WP_BASE_URL" \
        --title="$WP_TITLE" \
        --admin_user="$WP_ADMIN_USER" \
        --admin_password="$WP_ADMIN_PASS" \
        --admin_email="$WP_ADMIN_EMAIL" \
        --skip-email || {
        err "core install failed"
        return 1
    }

    WPCLI language core activate ru_RU >/dev/null 2>&1 || true

    wp_install_plugins || {
        err "plugin install failed"
        return 1
    }

    wp_create_pages
    WPCLI rewrite structure '/%postname%/' >/dev/null
    wp_write_htaccess
    wp_disable_autoupdates
    wp_perms

    log "WordPress installed. Admin user: $WP_ADMIN_USER"
    log "WordPress URL: $WP_BASE_URL"
    log "WordPress DB password file: $SECRET_DIR/wp_db_password"
    log "WordPress admin password file: $SECRET_DIR/wp_admin_password"

    return 0
}

wp_upgrade() {
    log "WP-bundle changed: applying offline upgrade..."

    WPCLI core update "$WP_INSTALLERS/wordpress-ru_RU.zip" --force || {
        err "core update failed"
        return 1
    }

    WPCLI core update-db || {
        err "core update-db failed"
        return 1
    }

    wp_install_plugins || {
        err "plugin upgrade failed"
        return 1
    }

    WPCLI rewrite flush >/dev/null
    wp_write_htaccess
    wp_disable_autoupdates
    wp_set_urls "$WP_BASE_URL"
    wp_perms

    log "WordPress upgraded offline."
    return 0
}

wp_perms() {
    chown -R www-data:www-data "$WP_DATA" 2>/dev/null || true
    chown -R www-data:www-data "$WP_DIR" 2>/dev/null || true

    find "$WP_DATA" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$WP_DATA" -type f -exec chmod 644 {} + 2>/dev/null || true

    find "$WP_DIR" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$WP_DIR" -type f -exec chmod 644 {} + 2>/dev/null || true

    if [ -f "$WP_DIR/wp-config.php" ]; then
        chmod 640 "$WP_DIR/wp-config.php"
    fi

    return 0
}

wp_set_urls() {
    local base="$1"
    local cur

    [ -f "$WP_DIR/wp-config.php" ] || return 0

    cur=$(WPCLI option get siteurl 2>/dev/null)

    if [ "$cur" != "$base" ]; then
        WPCLI option update siteurl "$base" >/dev/null 2>&1 || true
        WPCLI option update home "$base" >/dev/null 2>&1 || true
        log "WP URLs -> $base"
    fi

    return 0
}

# ------------------------------------------------------------------------------
# 07. Apache vhost.
#
# Нужен только если WordPress должен жить на отдельном домене WP_DOMAIN.
# Если WP_DOMAIN не задан, WordPress работает как подкаталог /wp
# в основном сайте Apache.
# ------------------------------------------------------------------------------
wp_configure_apache() {
    if [ -z "$WP_DOMAIN" ]; then
        return 0
    fi

    local conf="/etc/apache2/sites-available/mikrobill-wp.conf"
    local alias_line=""

    if [ -n "$WP_ALIAS" ]; then
        alias_line="    ServerAlias ${WP_ALIAS}"
    fi

    cat > "$conf" <<EOF
<VirtualHost *:80>
    ServerName ${WP_DOMAIN}
${alias_line}
    DocumentRoot ${WP_DIR}

    <Directory ${WP_DIR}>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/mikrobill-wp-error.log
    CustomLog \${APACHE_LOG_DIR}/mikrobill-wp-access.log combined
</VirtualHost>
EOF

    a2ensite mikrobill-wp >/dev/null 2>&1 || true
    apachectl graceful >/dev/null 2>&1 || true

    log "Apache vhost configured for $WP_DOMAIN"
    return 0
}

# ------------------------------------------------------------------------------
# 08. Основной сценарий модуля.
# ------------------------------------------------------------------------------
if ! wp_check_required_binaries; then
    err "Required binaries are missing; WordPress setup skipped"
    return 0 2>/dev/null || exit 0
fi

if ! wp_check_installer_bundle; then
    err "WordPress installer bundle is incomplete; WordPress setup skipped"
    return 0 2>/dev/null || exit 0
fi

if ! wp_ensure_database; then
    err "WordPress database preparation failed"
    return 0 2>/dev/null || exit 0
fi

BUNDLE_HASH=$(wp_bundle_hash)
INSTALLED_HASH_FILE="$WP_DATA/.wp_bundle_hash"

if [ ! -f "$WP_DIR/wp-config.php" ]; then
    if ! wp_first_install; then
        err "WordPress first install failed"
        return 0 2>/dev/null || exit 0
    fi

    printf '%s' "$BUNDLE_HASH" > "$INSTALLED_HASH_FILE"
else
    INSTALLED_HASH=$(cat "$INSTALLED_HASH_FILE" 2>/dev/null || echo "unknown")

    if [ "$BUNDLE_HASH" != "unknown" ] && [ "$INSTALLED_HASH" != "$BUNDLE_HASH" ]; then
        if ! wp_upgrade; then
            err "WordPress upgrade failed"
            return 0 2>/dev/null || exit 0
        fi

        printf '%s' "$BUNDLE_HASH" > "$INSTALLED_HASH_FILE"
    else
        log "WordPress already installed (bundle hash: $INSTALLED_HASH)"
        wp_set_urls "$WP_BASE_URL" || true
        wp_perms || true
    fi
fi

wp_configure_apache || true

log "WordPress module finished"
return 0 2>/dev/null || exit 0
