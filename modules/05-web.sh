#!/bin/bash

# ==============================================================================
# 05-web.sh
#
# Apache + опциональный WordPress (ENABLE_WP=1).
# Логика перенесена из legacy wp-setup.sh (сам wp-setup.sh в образ не входит).
#
# Принципы:
# - модуль source-ится: ошибки WordPress не должны ронять контейнер;
# - всё оффлайн из /opt/wp-installers, в рантайме ничего не скачивается;
# - сертификат выпускает ядро MikroBILL, мы только читаем его файлы;
# - подхват сертификата - при старте контейнера (рестарт после выдачи SAN);
# - Listen 443 принадлежит ядру (https.conf), мы его не пишем;
# - наш Apache-конфиг - один файл на диске + одна строка IncludeOptional;
# - миграций со старых релизов нет: обновление = repull + повторный setup.rsc.
#
# Блоки:
# 01. Запуск Apache.
# 02. Выход, если WordPress выключен.
# 03. Пути и переменные.
# 04. Служебные функции.
# 05. Секреты и база данных WordPress.
# 06. Сертификат ядра и проверка SAN.
# 07. Режим, базовый URL, сеть админки.
# 08. Apache: глобальный hardening и vhosts.
# 09. Установка и обновление WordPress.
# 10. Основной сценарий.
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
# 03. Пути и переменные.
#
# WP_DIR физически лежит в /mikrobill-data/web/wp: /var/www/html bind-монтируется
# из /mikrobill-data/web (модуль 02). Сертификаты ядра - /etc/apache2/cert,
# bind на /mikrobill-data/cert.
# ------------------------------------------------------------------------------
WP_INSTALLERS="${WP_INSTALLERS:-/opt/wp-installers}"

if [ ! -d "$WP_INSTALLERS" ] && [ -d /mikrobill-data/wp-installers ]; then
    WP_INSTALLERS=/mikrobill-data/wp-installers
fi

WP_DATA="${WP_DATA:-/mikrobill-data/web/wp}"
WP_DIR="${WP_DIR:-/var/www/html/wp}"

WP_DB_NAME="${WP_DB_NAME:-${DB_NAME:-mikrobill}_wp}"
WP_DB_USER="${WP_DB_USER:-${DB_USER:-mikrobill}_wp}"
WP_ADMIN_USER="${WP_ADMIN_USER:-wpadmin}"
WP_TITLE="${WP_TITLE:-MikroBILL Site}"

WP_DOMAIN="${WP_DOMAIN:-}"
WP_ALIAS="${WP_ALIAS:-}"
WP_ADMIN_NETWORKS="${WP_ADMIN_NETWORKS:-}"
MB_DOMAIN="${MB_DOMAIN:-}"

MB_APACHE_DIR="${MB_APACHE_DIR:-/mikrobill-data/apache}"
MB_APACHE_CONF="${MB_APACHE_DIR}/mb-wp.conf"
WP_LOG="${WP_LOG:-/mikrobill-data/wp.log}"
WP_STATE="${WP_DATA}/.wp_state"
ACME_HINT_FILE="${ACME_HINT_FILE:-/mikrobill-data/acme-cmd.txt}"

export WP_CLI_DISABLE_AUTO_CHECK_UPDATE=1

mkdir -p "$WP_DATA" "$WP_DIR" "$SECRET_DIR" "$MB_APACHE_DIR" \
         "${WEB_DIR}/.well-known/acme-challenge"

# ------------------------------------------------------------------------------
# 04. Служебные функции.
# ------------------------------------------------------------------------------
log() {
    local m
    m="$(date '+%Y-%m-%d %H:%M:%S') [wp] $*"
    echo "$m"
    echo "$m" >> "$WP_LOG" 2>/dev/null || true
}

err() {
    local m
    m="$(date '+%Y-%m-%d %H:%M:%S') [wp][error] $*"
    echo "$m" >&2
    echo "$m" >> "$WP_LOG" 2>/dev/null || true
}

if ! declare -F sql_escape >/dev/null 2>&1; then
    sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
fi

WPCLI() { wp --allow-root --path="$WP_DIR" "$@"; }

apache_running() {
    pidof apache2 >/dev/null 2>&1 || pgrep -x apache2 >/dev/null 2>&1
}

# Сколько активных (не закомментированных) Listen на порт во всём /etc/apache2.
# -R: sites-enabled и conf-enabled состоят из симлинков.
# Комментарии не матчатся якорем ^[[:space:]]*Listen.
mb_listen_count() {
    grep -RhE "^[[:space:]]*Listen[[:space:]]+([^[:space:]]*:)?$1([[:space:]]|$)" \
        /etc/apache2 2>/dev/null | wc -l | tr -d ' '
}

# Сеть из "ip/префикс": 192.168.88.10/24 -> 192.168.88.0/24
calc_service_net() {
    local cidr="$1" ip prefix o1 o2 o3 o4 ipint mask net
    ip=${cidr%/*}; prefix=${cidr#*/}
    IFS=. read -r o1 o2 o3 o4 <<<"$ip"
    ipint=$(( (o1<<24) + (o2<<16) + (o3<<8) + o4 ))
    mask=$(( (0xFFFFFFFF << (32-prefix)) & 0xFFFFFFFF ))
    net=$(( ipint & mask ))
    echo "$(( (net>>24)&255 )).$(( (net>>16)&255 )).$(( (net>>8)&255 )).$(( net&255 ))/$prefix"
}

wp_check_required_binaries() {
    local b missing=0
    for b in wp unzip openssl mysql; do
        if ! command -v "$b" >/dev/null 2>&1; then
            err "required binary not found: $b"
            missing=1
        fi
    done
    return "$missing"
}

wp_check_installer_bundle() {
    if [ ! -f "$WP_INSTALLERS/wordpress-ru_RU.zip" ]; then
        err "WordPress core archive not found: $WP_INSTALLERS/wordpress-ru_RU.zip"
        return 1
    fi
    return 0
}

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
# 05. Секреты и база данных WordPress.
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

wp_ensure_database() {
    local re='^[A-Za-z0-9_]+$' n u p

    if [[ ! "$WP_DB_NAME" =~ $re || ! "$WP_DB_USER" =~ $re ]]; then
        err "bad WP_DB_NAME/WP_DB_USER (allowed: A-Za-z0-9_)"
        return 1
    fi

    n=$(sql_escape "$WP_DB_NAME")
    u=$(sql_escape "$WP_DB_USER")
    p=$(sql_escape "$WP_DB_PASS")

    mysql -uroot <<SQL || { err "cannot create WordPress database/user"; return 1; }
CREATE DATABASE IF NOT EXISTS \`${n}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${u}'@'localhost' IDENTIFIED BY '${p}';
ALTER USER '${u}'@'localhost' IDENTIFIED BY '${p}';
GRANT ALL PRIVILEGES ON \`${n}\`.* TO '${u}'@'localhost';
REVOKE FILE ON *.* FROM '${u}'@'localhost';
CREATE USER IF NOT EXISTS '${u}'@'127.0.0.1' IDENTIFIED BY '${p}';
ALTER USER '${u}'@'127.0.0.1' IDENTIFIED BY '${p}';
GRANT ALL PRIVILEGES ON \`${n}\`.* TO '${u}'@'127.0.0.1';
REVOKE FILE ON *.* FROM '${u}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
    return 0
}

# ------------------------------------------------------------------------------
# 06. Сертификат ядра и проверка SAN.
#
# Ядро выпускает серт через acme и кладёт его в /etc/apache2/cert.
# Мы не выпускаем и не продлеваем ничего, только читаем.
# ------------------------------------------------------------------------------
WP_SSL_DIR="${WP_SSL_DIR:-/etc/apache2/cert}"
WP_SSL_CERT="${WP_SSL_CERT:-${WP_SSL_DIR}/mikrobill.crt}"
WP_SSL_KEY="${WP_SSL_KEY:-${WP_SSL_DIR}/mikrobill.key}"
WP_SSL_CHAIN="${WP_SSL_CHAIN:-${WP_SSL_DIR}/mikrobill.chain}"

wp_resolve_cert() {
    if [ -s "$WP_SSL_CERT" ] && [ -s "$WP_SSL_KEY" ]; then
        [ -s "$WP_SSL_CHAIN" ] || WP_SSL_CHAIN=""
        log "core certificate: $WP_SSL_CERT (chain: ${WP_SSL_CHAIN:-none})"
        return 0
    fi
    WP_SSL_CHAIN=""
    return 1
}

# Покрыто ли имя сертификатом (SAN, включая wildcard).
wp_cert_has_name() {
    local name san apex
    name=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    san=$(openssl x509 -in "$WP_SSL_CERT" -noout -ext subjectAltName 2>/dev/null)
    if [ -z "$san" ]; then
        san=$(openssl x509 -in "$WP_SSL_CERT" -noout -text 2>/dev/null \
              | grep -A1 'Subject Alternative Name')
    fi
    san=$(printf '%s' "$san" | tr 'A-Z' 'a-z' | tr -d ' ')
    case "$san" in *"dns:${name}"*) return 0;; esac
    apex=${name#www.}
    case "$san" in *"dns:*.${apex}"*) return 0;; esac
    return 1
}

# ------------------------------------------------------------------------------
# 07. Режим, базовый URL, сеть админки.
#
# WP_DOMAIN пуст -> PORT: vhost *:8080, наружу не публикуется.
# WP_DOMAIN задан -> NAME: 80/443 по имени, apex -> www.
# ------------------------------------------------------------------------------
CONTAINER_IP="${CONTAINER_IP:-}"
if [ -z "$CONTAINER_IP" ]; then
    CONTAINER_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [ -n "$CONTAINER_IP" ] || CONTAINER_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
    err "CONTAINER_IP not set in env, autodetected: ${CONTAINER_IP:-unknown}"
fi
CONTAINER_MASK="${CONTAINER_MASK:-24}"

REQ_IP=""
if [ -n "${CONTAINER_IP:-}" ]; then
    REQ_IP=$(calc_service_net "${CONTAINER_IP}/${CONTAINER_MASK}")
fi
if [ -n "$WP_ADMIN_NETWORKS" ]; then
    REQ_IP="$REQ_IP $(printf '%s' "$WP_ADMIN_NETWORKS" | tr ',' ' ' | tr -s ' ')"
fi
REQ_IP=$(printf '%s' "$REQ_IP" | sed 's/^ *//;s/ *$//')

WP_CERT=0
APEX=""

if [ -n "$WP_DOMAIN" ]; then
    WP_MODE=name
    case "$WP_DOMAIN" in www.*) APEX="${WP_DOMAIN#www.}";; esac
    WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-admin@${WP_DOMAIN#www.}}"
    WP_BASE_URL="http://${WP_DOMAIN}"

    if wp_resolve_cert; then
        if wp_cert_has_name "$WP_DOMAIN"; then
            WP_CERT=1
            WP_BASE_URL="https://${WP_DOMAIN}"
        else
            err "certificate has no SAN for $WP_DOMAIN - staying on HTTP"
        fi
    else
        log "no core certificate yet - WordPress serves HTTP"
    fi

    # Подсказка для ручной правки строки acme в GUI ядра.
    {
        printf '# Paste into MikroBILL GUI (ACME command line), then restart container.\n'
        printf '# DNS A for all names must point to the published white IP.\n'
        printf -- '--force --issue -d %s -d %s' "${MB_DOMAIN:-<lk-domain>}" "$WP_DOMAIN"
        [ -n "$APEX" ] && printf -- ' -d %s' "$APEX"
        printf -- ' --webroot %s\n' "$WEB_DIR"
    } > "$ACME_HINT_FILE" 2>/dev/null || true

    if [ "$WP_CERT" != 1 ]; then
        log "SAN hint written to $ACME_HINT_FILE:"
        log "$(grep -v '^#' "$ACME_HINT_FILE" 2>/dev/null | head -1)"
    fi
else
    WP_MODE=port
    WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-admin@example.com}"
    WP_BASE_URL="http://${CONTAINER_IP:-127.0.0.1}:8080"
fi

# WP-CLI не принимает невалидный e-mail: admin@localhost ломал core install.
if ! printf '%s' "$WP_ADMIN_EMAIL" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'; then
    err "WP_ADMIN_EMAIL '$WP_ADMIN_EMAIL' is invalid, using admin@example.com"
    WP_ADMIN_EMAIL="admin@example.com"
fi

log "mode=$WP_MODE base=$WP_BASE_URL cert=$WP_CERT admin-net=${REQ_IP:-any}"

# ------------------------------------------------------------------------------
# 08. Apache: глобальный hardening и vhosts.
#
# Listen 443 НЕ пишем: им владеет ядро (https.conf), а на свежем образе его
# даёт ports.conf. Дубликат Listen роняет Apache на bind, поэтому только warn.
#
# Hardening и Require ip - в глобальном scope: WP_DIR внутри WEB_DIR, и через
# дефолтный vhost ядра путь /wp/... обходил бы ограничение по сети.
# ------------------------------------------------------------------------------
mb_global_block() {
    cat <<EOF
<IfModule php_module>
    <Directory ${WP_DIR}/wp-content/uploads>
        php_admin_flag engine off
        <FilesMatch "\.php\$">
            Require all denied
        </FilesMatch>
    </Directory>
    <Directory ${WP_DIR}/wp-includes>
        php_admin_flag engine off
        <FilesMatch "\.php\$">
            Require all denied
        </FilesMatch>
    </Directory>
</IfModule>
<FilesMatch "^(wp-config\.php|\.htaccess|\.user\.ini)">
    Require all denied
</FilesMatch>
<LocationMatch "^/(wp/)?xmlrpc\.php">
    Require all denied
</LocationMatch>
EOF

    if [ -n "$REQ_IP" ]; then
        cat <<EOF
<LocationMatch "^/(wp/)?wp-login\.php">
    Require ip ${REQ_IP}
</LocationMatch>
<LocationMatch "^/(wp/)?wp-admin/(?!admin-ajax\.php|admin-post\.php)">
    Require ip ${REQ_IP}
</LocationMatch>
EOF
    else
        echo "# admin network unknown: wp-admin/wp-login are NOT restricted"
    fi
}

# HTTP-01: ядро валидирует через --webroot WEB_DIR, поэтому challenge отдаём
# оттуда и в WP-vhost, и в apex-редиректе.
mb_acme_block() {
    cat <<EOF
    Alias /.well-known/acme-challenge/ ${WEB_DIR}/.well-known/acme-challenge/
    <Directory ${WEB_DIR}/.well-known/acme-challenge>
        Options None
        AllowOverride None
        Require all granted
    </Directory>
EOF
}

mb_docroot_block() {
    cat <<EOF
    DocumentRoot ${WP_DIR}
    <Directory ${WP_DIR}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
EOF
}

# Параметры как в https.conf ядра.
mb_ssl_block() {
    cat <<EOF
    SSLEngine on
    SSLProtocol all -SSLv2 -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite HIGH:!aNULL:!MD5:!3DES:!CAMELLIA:!DSS:!DH
    SSLHonorCipherOrder on
    SSLCertificateFile "${WP_SSL_CERT}"
    SSLCertificateKeyFile "${WP_SSL_KEY}"
EOF
    [ -n "$WP_SSL_CHAIN" ] && printf '    SSLCertificateChainFile "%s"\n' "$WP_SSL_CHAIN"
}

mb_logs_block() {
    cat <<EOF
    ErrorLog \${APACHE_LOG_DIR}/mb-$1-error.log
    CustomLog \${APACHE_LOG_DIR}/mb-$1-access.log combined
EOF
}

wp_write_apache() {
    local target="http://${WP_DOMAIN}" n443
    [ "$WP_CERT" = 1 ] && target="https://${WP_DOMAIN}"

    {
        echo "# MikroBILL WordPress - generated by modules/05-web.sh, do not edit"
        echo "# mode=${WP_MODE} domain=${WP_DOMAIN:-none} cert=${WP_CERT}"
        mb_global_block

        if [ "$WP_MODE" = port ]; then
            [ "$(mb_listen_count 8080)" = 0 ] && echo "Listen 8080"
            cat <<EOF
<VirtualHost *:8080>
    ServerName ${CONTAINER_IP:-localhost}
$(mb_docroot_block)
$(mb_logs_block wp-port)
</VirtualHost>
EOF
            return 0
        fi

        # --- 80: основной домен ---
        echo "<VirtualHost *:80>"
        echo "    ServerName ${WP_DOMAIN}"
        [ -n "$WP_ALIAS" ] && echo "    ServerAlias ${WP_ALIAS}"
        mb_acme_block
        if [ "$WP_CERT" = 1 ]; then
            cat <<EOF
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^/(.*)\$ https://${WP_DOMAIN}/\$1 [R=301,L]
EOF
        else
            mb_docroot_block
        fi
        mb_logs_block wp-http
        echo "</VirtualHost>"

        # --- 80: apex -> основной домен ---
        if [ -n "$APEX" ]; then
            cat <<EOF
<VirtualHost *:80>
    ServerName ${APEX}
$(mb_acme_block)
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^/(.*)\$ ${target}/\$1 [R=301,L]
$(mb_logs_block wp-apex)
</VirtualHost>
EOF
        fi

        # --- 443: форма адреса как у ядра (0.0.0.0:443) ---
        if [ "$WP_CERT" = 1 ]; then
            n443=$(mb_listen_count 443)
            if [ "$n443" = 0 ]; then
                echo "# WARNING: no active Listen 443 found - core https.conf missing?"
            elif [ "$n443" != 1 ]; then
                echo "# WARNING: $n443 active Listen 443 directives - Apache may fail to bind"
            fi

            cat <<EOF
<IfModule mod_ssl.c>
# Catch-all: наши vhosts читаются раньше https.conf ядра, поэтому непопавший
# Host на 443 должен отдавать web ядра, а не WordPress.
<VirtualHost 0.0.0.0:443>
    ServerName mb-default.invalid
$(mb_ssl_block)
    DocumentRoot ${WEB_DIR}
    <Directory ${WEB_DIR}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
$(mb_acme_block)
$(mb_logs_block wp-default)
</VirtualHost>
<VirtualHost 0.0.0.0:443>
    ServerName ${WP_DOMAIN}
EOF
            [ -n "$WP_ALIAS" ] && echo "    ServerAlias ${WP_ALIAS}"
            mb_ssl_block
            mb_acme_block
            mb_docroot_block
            mb_logs_block wp-ssl
            echo "</VirtualHost>"

            if [ -n "$APEX" ]; then
                cat <<EOF
<VirtualHost 0.0.0.0:443>
    ServerName ${APEX}
$(mb_ssl_block)
    RewriteEngine On
    RewriteRule ^/(.*)\$ https://${WP_DOMAIN}/\$1 [R=301,L]
$(mb_logs_block wp-apex-ssl)
</VirtualHost>
EOF
            fi
            echo "</IfModule>"
        fi
    } > "$MB_APACHE_CONF"
}

wp_apache_apply() {
    local out i f

    # Одна строка Include на весь наш конфиг; IncludeOptional - чтобы Apache
    # не падал, когда файла нет (WP выключен, диск не смонтирован).
    if ! grep -qF "IncludeOptional ${MB_APACHE_DIR}/" /etc/apache2/apache2.conf 2>/dev/null; then
        printf '\n# MikroBILL WordPress (modules/05-web.sh)\nIncludeOptional %s/*.conf\n' \
            "$MB_APACHE_DIR" >> /etc/apache2/apache2.conf
        log "IncludeOptional added to apache2.conf"
    fi

    wp_write_apache

    if ! out=$(apachectl configtest 2>&1); then
        err "Apache configtest failed, disabling WP snippet to keep billing web alive:"
        printf '%s\n' "$out" >&2
        # apache2.conf ядра содержит plain Include https.conf / admin.conf:
        # отсутствие любого из них роняет Apache независимо от нас.
        for f in /etc/apache2/https.conf /etc/apache2/admin.conf; do
            [ -f "$f" ] || err "missing core config: $f (plain Include in apache2.conf)"
        done
        mv -f "$MB_APACHE_CONF" "${MB_APACHE_CONF}.bad" 2>/dev/null || true
        apachectl configtest >/dev/null 2>&1 || err "Apache config still broken after disabling WP snippet"
    fi

    # graceful, а не restart: restart гонится со старым мастером за :80.
    for i in 1 2 3; do
        if apache_running; then
            out=$(apachectl graceful 2>&1) && break
        else
            out=$(apachectl start 2>&1) && break
        fi
        err "Apache apply attempt $i failed: $out"
        sleep 2
    done

    if ! apache_running; then
        err "Apache is NOT running after apply"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 09. Установка и обновление WordPress.
# ------------------------------------------------------------------------------
build_extra_php() {
    local k
    printf "define('FS_METHOD','direct');\n"
    printf "define('DISALLOW_FILE_EDIT',true);\n"
    printf "define('WP_AUTO_UPDATE_CORE',false);\n"
    printf "define('AUTOMATIC_UPDATER_DISABLED',true);\n"
    printf "define('WP_DEBUG',false);\n"
    printf "define('WP_MEMORY_LIMIT','256M');\n"
    printf "define('WP_MAX_MEMORY_LIMIT','512M');\n"
    for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        printf "define('%s','%s');\n" "$k" "$(openssl rand -base64 48)"
    done
}

ensure_page() {
    local slug="$1" title="$2" content="$3" id
    id=$(WPCLI post list --post_type=page --name="$slug" --field=ID 2>/dev/null | head -1)
    if [ -z "$id" ]; then
        id=$(WPCLI post create --post_type=page --post_status=publish \
             --post_title="$title" --post_name="$slug" --post_content="$content" --porcelain)
    fi
    printf '%s' "$id"
}

wp_create_pages() {
    local home_id
    home_id=$(ensure_page home "Главная" "<!-- wp:paragraph --><p>Добро пожаловать на сайт оператора связи. Отредактируйте эту страницу в админке.</p><!-- /wp:paragraph -->")
    ensure_page tariffs "Тарифы" "<!-- wp:paragraph --><p>Здесь разместите описание тарифов.</p><!-- /wp:paragraph -->" >/dev/null
    ensure_page contacts "Контакты" "<!-- wp:paragraph --><p>Телефон, e-mail, адрес и форму обратной связи добавьте здесь.</p><!-- /wp:paragraph -->" >/dev/null
    ensure_page privacy "Политика обработки персональных данных" "<!-- wp:paragraph --><p>Разместите текст политики обработки персональных данных.</p><!-- /wp:paragraph -->" >/dev/null
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
    local p
    if [ ! -f "$WP_INSTALLERS/kadence.zip" ]; then
        err "theme archive not found: $WP_INSTALLERS/kadence.zip"
        return 1
    fi
    WPCLI theme install "$WP_INSTALLERS/kadence.zip" --activate --force || {
        err "theme install failed: kadence"; return 1; }

    for p in kadence-blocks fluentform fluent-smtp limit-login-attempts-reloaded updraftplus; do
        if [ ! -f "$WP_INSTALLERS/$p.zip" ]; then
            err "plugin archive not found: $WP_INSTALLERS/$p.zip"
            return 1
        fi
        WPCLI plugin install "$WP_INSTALLERS/$p.zip" --activate --force || {
            err "plugin install failed: $p"; return 1; }
    done

    mkdir -p "$WP_DIR/wp-content/mu-plugins"
    if [ ! -f "$WP_INSTALLERS/mu-plugins/mikrobill-guard.php" ]; then
        err "mu-plugin not found: $WP_INSTALLERS/mu-plugins/mikrobill-guard.php"
        return 1
    fi
    cp -f "$WP_INSTALLERS/mu-plugins/mikrobill-guard.php" \
          "$WP_DIR/wp-content/mu-plugins/mikrobill-guard.php" || {
        err "cannot install mu-plugin"; return 1; }
    return 0
}

wp_write_htaccess() {
    cat > "$WP_DIR/.htaccess" <<'EOF'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
EOF
    chown www-data:www-data "$WP_DIR/.htaccess" 2>/dev/null || true
    chmod 644 "$WP_DIR/.htaccess"
}

wp_perms() {
    chown -R www-data:www-data "$WP_DIR" 2>/dev/null || true
    find "$WP_DIR" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$WP_DIR" -type f -exec chmod 644 {} + 2>/dev/null || true
    [ -f "$WP_DIR/wp-config.php" ] && chmod 640 "$WP_DIR/wp-config.php"
    return 0
}

# Адрес меняет только entrypoint: guard запрещает siteurl/home из админки.
wp_set_urls() {
    local base="$1" cur
    [ -f "$WP_DIR/wp-config.php" ] || return 0
    cur=$(WPCLI option get siteurl 2>/dev/null)
    [ -n "$cur" ] || return 0
    [ "$cur" = "$base" ] && return 0

    # Не понижаем работающий https, если сертификата сейчас нет.
    case "$cur" in
        https://*)
            if [ "$WP_CERT" != 1 ]; then
                err "siteurl is https but certificate is missing - keeping $cur"
                return 0
            fi
            ;;
    esac

    WPCLI option update siteurl "$base" >/dev/null 2>&1 || true
    WPCLI option update home "$base" >/dev/null 2>&1 || true
    log "WP URLs -> $base"
    return 0
}

wp_first_install() {
    local prefix extra
    log "first run: installing WordPress offline (base=$WP_BASE_URL)"

    rm -rf /tmp/wp-core; mkdir -p /tmp/wp-core
    unzip -qo "$WP_INSTALLERS/wordpress-ru_RU.zip" -d /tmp/wp-core || { err "core unzip failed"; return 1; }
    cp -a /tmp/wp-core/wordpress/. "$WP_DIR/" || { err "cannot copy core to $WP_DIR"; return 1; }
    rm -rf /tmp/wp-core

    prefix="mbwp_$(openssl rand -hex 3)_"
    extra=$(build_extra_php)

    WPCLI config create \
        --dbname="$WP_DB_NAME" --dbuser="$WP_DB_USER" --dbpass="$WP_DB_PASS" \
        --dbhost=localhost --dbcharset=utf8mb4 --dbcollate=utf8mb4_unicode_ci \
        --dbprefix="$prefix" --skip-salts --extra-php="$extra" --force || {
        err "config create failed"; return 1; }

    WPCLI core install \
        --url="$WP_BASE_URL" --title="$WP_TITLE" \
        --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASS" \
        --admin_email="$WP_ADMIN_EMAIL" --skip-email || {
        err "core install failed"; return 1; }

    WPCLI language core activate ru_RU >/dev/null 2>&1 || true
    wp_install_plugins || return 1
    wp_create_pages
    WPCLI rewrite structure '/%postname%/' >/dev/null
    wp_write_htaccess
    wp_disable_autoupdates
    wp_perms

    log "WordPress installed. Admin: $WP_ADMIN_USER, e-mail: $WP_ADMIN_EMAIL"
    log "passwords: $SECRET_DIR/wp_admin_password, $SECRET_DIR/wp_db_password"
    return 0
}

wp_upgrade() {
    log "WP-bundle changed: applying offline upgrade"
    WPCLI core update "$WP_INSTALLERS/wordpress-ru_RU.zip" --force || { err "core update failed"; return 1; }
    WPCLI core update-db || { err "core update-db failed"; return 1; }
    wp_install_plugins || return 1
    WPCLI rewrite flush >/dev/null
    wp_write_htaccess
    wp_disable_autoupdates
    wp_perms
    log "WordPress upgraded offline"
    return 0
}

# ------------------------------------------------------------------------------
# 10. Основной сценарий. Любая ошибка WP - мягкий выход, контейнер живёт.
# ------------------------------------------------------------------------------
if ! wp_check_required_binaries; then
    err "required binaries missing; WordPress skipped"
    return 0 2>/dev/null || exit 0
fi

if ! wp_check_installer_bundle; then
    err "WP bundle incomplete; WordPress skipped"
    return 0 2>/dev/null || exit 0
fi

if ! wp_ensure_database; then
    err "WordPress database preparation failed"
    return 0 2>/dev/null || exit 0
fi

wp_apache_apply || err "Apache vhost apply had errors"

BUNDLE_HASH=$(wp_bundle_hash)
INSTALLED_HASH_FILE="$WP_DATA/.wp_bundle_hash"

if [ -f "$WP_DIR/wp-config.php" ] && WPCLI core is-installed >/dev/null 2>&1; then
    INSTALLED_HASH=$(cat "$INSTALLED_HASH_FILE" 2>/dev/null || echo "unknown")
    if [ "$BUNDLE_HASH" != "unknown" ] && [ "$INSTALLED_HASH" != "$BUNDLE_HASH" ]; then
        if wp_upgrade; then
            printf '%s' "$BUNDLE_HASH" > "$INSTALLED_HASH_FILE"
        else
            err "WordPress upgrade FAILED - MikroBILL continues"
        fi
    else
        log "WordPress already installed (bundle hash: $INSTALLED_HASH)"
        wp_perms || true
    fi
else
    if wp_first_install; then
        printf '%s' "$BUNDLE_HASH" > "$INSTALLED_HASH_FILE"
    else
        err "WordPress first install FAILED - MikroBILL continues"
    fi
fi

wp_set_urls "$WP_BASE_URL" || true

cat > "$WP_STATE" <<EOF
WP_MODE='${WP_MODE}'
WP_DOMAIN='${WP_DOMAIN}'
WP_BASE_URL='${WP_BASE_URL}'
WP_CERT='${WP_CERT}'
EOF

if [ "$WP_MODE" = port ]; then
    log "WordPress ready (PORT): $WP_BASE_URL - service network only, 8080 not published"
else
    log "WordPress ready (NAME): $WP_BASE_URL - admin nets: ${REQ_IP:-any}"
fi

log "WordPress module finished"
return 0 2>/dev/null || exit 0
