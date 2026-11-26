#!/bin/bash
# MikroBILL: optional WordPress-визитка. Вызывается из entrypoint.sh при ENABLE_WP=1.
# Только WP: vhost MikroBILL не трогаем (им управляет сам MikroBILL).
# Оффлайн-установка/обновление из /opt/wp-installers (WP-bundle).
#
# Режимы:
#   WP_DOMAIN не задан -> PORT mode: vhost *:8080, siteurl=http://CONTAINER_IP:8080,
#                        доступно только из служебной сети (8080 не публикуется через NAT).
#   WP_DOMAIN задан     -> NAME mode: vhost по имени на 80/443, админка ограничена Require ip.
#
# Сеть админки: считается из CONTAINER_IP/CONTAINER_MASK (пишет генератор в envs),
#               дополнительно расширяется через WP_ADMIN_NETWORKS.
set -u

WP_INSTALLERS=/opt/wp-installers
WP_DIR=/var/www/site                 # symlink -> /mikrobill-data/wp
WP_DATA=/mikrobill-data/wp
SECRET_DIR=/mikrobill-data/secrets
SSL_DIR=/mikrobill-data/ssl
ACME_HOME=/mikrobill-data/acme
ACME_BIN=/root/.acme.sh/acme.sh
APACHE_AVAIL=/etc/apache2/sites-available
ENV_FILE=/mikrobill-data/wp-env.sh
STATE_FILE="$WP_DATA/.mb-wp-state"
export WP_CLI_DISABLE_AUTO_CHECK_UPDATE=1

# Свой лог в UTF-8: читается через `cat /mikrobill-data/wp-setup.log`,
# а не через /log микрота (там ломается кириллица).
exec > >(tee -a /mikrobill-data/wp-setup.log) 2>&1

log()  { echo "[wp] $*"; }
warn() { echo "[wp] WARNING: $*"; }
err()  { echo "[wp] ERROR: $*"; }
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# ---------- Apache shared blocks ----------
ACME_BLOCK=$(cat <<'EOF'
    Alias /.well-known/acme-challenge/ /var/www/letsencrypt/.well-known/acme-challenge/
    <Directory /var/www/letsencrypt/.well-known/acme-challenge>
        Options None
        AllowOverride None
        Require all granted
    </Directory>
EOF
)

WP_HARDEN=$(cat <<'EOF'
    <Location "/xmlrpc.php">
        Require all denied
    </Location>
    <FilesMatch "^(wp-config\.php|\.htaccess|\.user\.ini)">
        Require all denied
    </FilesMatch>
    <Directory /var/www/site/wp-content/uploads>
        php_admin_flag engine off
        <FilesMatch "\.php$">
            Require all denied
        </FilesMatch>
    </Directory>
    <Directory /var/www/site/wp-includes>
        php_admin_flag engine off
        <FilesMatch "\.php$">
            Require all denied
        </FilesMatch>
    </Directory>
EOF
)

WP_DOCROOT_BLOCK=$(cat <<'EOF'
    DocumentRoot /var/www/site
    <Directory /var/www/site>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
EOF
)

# NAME mode: дашборд/вход только служебная сеть; admin-ajax/admin-post открыты (формы).
wp_admin_restrict() {
cat <<EOF
    <LocationMatch "^/wp-admin/(?!admin-ajax\.php|admin-post\.php)">
        Require ip $REQ_IP
    </LocationMatch>
    <Location "/wp-login.php">
        Require ip $REQ_IP
    </Location>
EOF
}

# ---------- network ----------
# Адрес сети из "ip/префикс". Пример: 192.168.88.10/24 -> 192.168.88.0/24.
calc_service_net() {
    local cidr="$1" ip prefix o1 o2 o3 o4 ipint mask net
    ip=${cidr%/*}; prefix=${cidr#*/}
    IFS=. read -r o1 o2 o3 o4 <<<"$ip"
    ipint=$(( (o1<<24) + (o2<<16) + (o3<<8) + o4 ))
    mask=$(( (0xFFFFFFFF << (32-prefix)) & 0xFFFFFFFF ))
    net=$(( ipint & mask ))
    echo "$(( (net>>24)&255 )).$(( (net>>16)&255 )).$(( (net>>8)&255 )).$(( net&255 ))/$prefix"
}

apache_running() {
    pidof apache2 >/dev/null 2>&1 || pgrep -x apache2 >/dev/null 2>&1
}

# ---------- prepare ----------
wp_prepare() {
    mkdir -p "$WP_DATA" "$SECRET_DIR" "$SSL_DIR" /var/www/letsencrypt/.well-known/acme-challenge
    if [ -d "$WP_DIR" ] && [ ! -L "$WP_DIR" ]; then rm -rf "$WP_DIR"; fi
    ln -sfn "$WP_DATA" "$WP_DIR"

    if [ ! -s "$SECRET_DIR/wp_db_password" ]; then openssl rand -hex 16 > "$SECRET_DIR/wp_db_password"; fi
    if [ ! -s "$SECRET_DIR/wp_admin_password" ]; then openssl rand -hex 12 > "$SECRET_DIR/wp_admin_password"; fi
    chmod 600 "$SECRET_DIR/wp_db_password" "$SECRET_DIR/wp_admin_password"
    WP_DB_PASS=$(cat "$SECRET_DIR/wp_db_password")
    WP_ADMIN_PASS=$(cat "$SECRET_DIR/wp_admin_password")
    log "WP DB password file: $SECRET_DIR/wp_db_password"
    log "WP admin password file: $SECRET_DIR/wp_admin_password"

    WP_DB_NAME=${WP_DB_NAME:-wordpress}
    WP_DB_USER=${WP_DB_USER:-wpuser}
    WP_ADMIN_USER=${WP_ADMIN_USER:-operator}
    WP_TITLE=${WP_TITLE:-Operator}
    local re='^[A-Za-z0-9_]+$'
    [[ "$WP_DB_NAME" =~ $re && "$WP_DB_USER" =~ $re ]] || { err "bad WP_DB_NAME/WP_DB_USER"; return 1; }

    local n u p
    n=$(sql_escape "$WP_DB_NAME"); u=$(sql_escape "$WP_DB_USER"); p=$(sql_escape "$WP_DB_PASS")
    mysql -uroot <<SQL || { err "cannot create WP database"; return 1; }
CREATE DATABASE IF NOT EXISTS \`${n}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${u}'@'localhost' IDENTIFIED BY '${p}';
ALTER USER '${u}'@'localhost' IDENTIFIED BY '${p}';
GRANT ALL PRIVILEGES ON \`${n}\`.* TO '${u}'@'localhost';
REVOKE FILE ON *.* FROM '${u}'@'localhost';
FLUSH PRIVILEGES;
SQL

    # Единственный источник правды — envs из setup.rsc.
    IP=${CONTAINER_IP:-}
    [ -n "$IP" ] || { err "CONTAINER_IP not set in env - check setup.rsc"; return 1; }
    MASK=${CONTAINER_MASK:-24}
    SERVICE_NET=$(calc_service_net "$IP/$MASK")
    EXTRA_NETS=$(printf '%s' "${WP_ADMIN_NETWORKS:-}" | tr ',' ' ' | tr -s ' ')
    REQ_IP="$SERVICE_NET $EXTRA_NETS"

    if [ -n "${WP_DOMAIN:-}" ]; then
        MODE=name
        case "$WP_DOMAIN" in www.*) APEX="${WP_DOMAIN#www.}";; *) APEX="";; esac
        WP_ADMIN_EMAIL=${WP_ADMIN_EMAIL:-admin@${WP_DOMAIN#www.}}
        BASE="http://$WP_DOMAIN"
        [ -s "$SSL_DIR/fullchain.pem" ] && BASE="https://$WP_DOMAIN"
    else
        MODE=port
        APEX=""
        WP_ADMIN_EMAIL=${WP_ADMIN_EMAIL:-admin@example.com}
        BASE="http://${IP}:8080"
    fi
    log "mode=$MODE base=$BASE admin-net=$REQ_IP"

    cat > "$ENV_FILE" <<EOF
ENABLE_WP=1
WP_DOMAIN='${WP_DOMAIN:-}'
WP_MODE='$MODE'
APEX='$APEX'
IP='$IP'
MASK='$MASK'
SERVICE_NET='$SERVICE_NET'
EXTRA_NETS='$EXTRA_NETS'
REQ_IP='$REQ_IP'
WP_DIR='$WP_DIR'
SSL_DIR='$SSL_DIR'
EOF
}

# ---------- wp-config extra PHP ----------
build_extra_php() {
    local s k
    s="define('FS_METHOD','direct');\n"
    s+="define('DISALLOW_FILE_EDIT',true);\n"
    s+="define('WP_AUTO_UPDATE_CORE',false);\n"
    s+="define('AUTOMATIC_UPDATER_DISABLED',true);\n"
    s+="define('WP_DEBUG',false);\n"
    s+="define('WP_MEMORY_LIMIT','256M');\n"
    s+="define('WP_MAX_MEMORY_LIMIT','512M');\n"
    for k in AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
        s+="define('$k','$(openssl rand -base64 48)');\n"
    done
    printf '%b' "$s"
}

WPCLI() { wp --allow-root --path="$WP_DIR" "$@"; }

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
    WPCLI theme install "$WP_INSTALLERS/kadence.zip" --activate --force
    local p
    for p in kadence-blocks fluentform fluent-smtp limit-login-attempts-reloaded updraftplus; do
        WPCLI plugin install "$WP_INSTALLERS/$p.zip" --activate --force
    done
    mkdir -p "$WP_DIR/wp-content/mu-plugins"
    cp -f "$WP_INSTALLERS/mu-plugins/mikrobill-guard.php" "$WP_DIR/wp-content/mu-plugins/mikrobill-guard.php"
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

wp_first_install() {
    log "First run: installing WordPress offline (base=$BASE)..."
    rm -rf /tmp/wp-core; mkdir -p /tmp/wp-core
    unzip -qo "$WP_INSTALLERS/wordpress-ru_RU.zip" -d /tmp/wp-core || { err "core unzip failed"; return 1; }
    cp -a /tmp/wp-core/wordpress/. "$WP_DIR/"
    rm -rf /tmp/wp-core

    local prefix extra
    prefix="mbwp_$(openssl rand -hex 3)_"
    extra=$(build_extra_php)
    WPCLI config create \
        --dbname="$WP_DB_NAME" --dbuser="$WP_DB_USER" --dbpass="$WP_DB_PASS" \
        --dbhost=localhost --dbcharset=utf8mb4 --dbcollate=utf8mb4_unicode_ci \
        --dbprefix="$prefix" --skip-salts --extra-php="$extra" --force || { err "config create failed"; return 1; }

    WPCLI core install \
        --url="$BASE" --title="$WP_TITLE" \
        --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASS" \
        --admin_email="$WP_ADMIN_EMAIL" --skip-email || { err "core install failed"; return 1; }

    WPCLI language core activate ru_RU >/dev/null 2>&1 || true
    wp_install_plugins || { err "plugin install failed"; return 1; }
    wp_create_pages
    WPCLI rewrite structure '/%postname%/' >/dev/null
    wp_write_htaccess
    wp_disable_autoupdates
    log "WordPress installed (admin user: $WP_ADMIN_USER)."
}

wp_upgrade() {
    log "WP-bundle changed: applying offline upgrade..."
    WPCLI core update "$WP_INSTALLERS/wordpress-ru_RU.zip" --force || { err "core update failed"; return 1; }
    WPCLI core update-db || { err "core update-db failed"; return 1; }
    wp_install_plugins || { err "plugin upgrade failed"; return 1; }
    WPCLI rewrite flush >/dev/null
    wp_write_htaccess
    wp_disable_autoupdates
    log "WordPress upgraded offline."
}

wp_perms() {
    chown -R www-data:www-data "$WP_DATA" 2>/dev/null || true
    find "$WP_DATA" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$WP_DATA" -type f -exec chmod 644 {} + 2>/dev/null || true
    [ -f "$WP_DIR/wp-config.php" ] && chmod 640 "$WP_DIR/wp-config.php"
}

wp_set_urls() {
    local base="$1" cur
    [ -f "$WP_DIR/wp-config.php" ] || return 0
    cur=$(WPCLI option get siteurl 2>/dev/null)
    if [ "$cur" != "$base" ]; then
        WPCLI option update siteurl "$base" >/dev/null 2>&1 || true
        WPCLI option update home "$base" >/dev/null 2>&1 || true
        log "WP URLs -> $base"
    fi
}

# ---------- Apache vhosts ----------
wp_apache_port() {
    cat > "$APACHE_AVAIL/mb-wp.conf" <<EOF
# MikroBILL WordPress - PORT mode (no domain), generated by wp-setup.sh
<VirtualHost *:8080>
    ServerName $IP
$WP_DOCROOT_BLOCK
$WP_HARDEN
</VirtualHost>
EOF
}

wp_apache_name() {
    local cert="$1" f="$APACHE_AVAIL/mb-wp.conf"
    echo "# MikroBILL WordPress - NAME mode, generated by wp-setup.sh" > "$f"
    if [ "$cert" = 1 ]; then
        cat >> "$f" <<EOF
<VirtualHost *:80>
    ServerName $WP_DOMAIN
$ACME_BLOCK
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^/(.*)\$ https://$WP_DOMAIN/\$1 [R=301,L]
</VirtualHost>
EOF
    else
        cat >> "$f" <<EOF
<VirtualHost *:80>
    ServerName $WP_DOMAIN
$ACME_BLOCK
$WP_DOCROOT_BLOCK
$WP_HARDEN
$(wp_admin_restrict)
</VirtualHost>
EOF
    fi
    if [ -n "$APEX" ]; then
        local target="http://$WP_DOMAIN"; [ "$cert" = 1 ] && target="https://$WP_DOMAIN"
        cat >> "$f" <<EOF
<VirtualHost *:80>
    ServerName $APEX
$ACME_BLOCK
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^/(.*)\$ $target/\$1 [R=301,L]
</VirtualHost>
EOF
    fi
}

wp_apache_ssl() {
    local f="$APACHE_AVAIL/mb-wp-ssl.conf" apex_part=""
    if [ -n "$APEX" ]; then
        apex_part=$(cat <<EOF
<VirtualHost *:443>
    ServerName $APEX
    SSLEngine on
    SSLCertificateFile $SSL_DIR/fullchain.pem
    SSLCertificateKeyFile $SSL_DIR/privkey.pem
    RewriteEngine On
    RewriteRule ^/(.*)\$ https://$WP_DOMAIN/\$1 [R=301,L]
</VirtualHost>
EOF
)
    fi
    cat > "$f" <<EOF
<IfModule mod_ssl.c>
<VirtualHost *:443>
    ServerName $WP_DOMAIN
    SSLEngine on
    SSLCertificateFile $SSL_DIR/fullchain.pem
    SSLCertificateKeyFile $SSL_DIR/privkey.pem
$ACME_BLOCK
$WP_DOCROOT_BLOCK
$WP_HARDEN
$(wp_admin_restrict)
</VirtualHost>
$apex_part
</IfModule>
EOF
}

wp_apache_apply() {
    local mode="$1" cert="$2" out i
    if [ "$mode" = port ]; then
        wp_apache_port
        grep -q '^Listen 8080' /etc/apache2/ports.conf 2>/dev/null || echo 'Listen 8080' >> /etc/apache2/ports.conf
        a2dissite mb-wp-ssl >/dev/null 2>&1 || true
        rm -f "$APACHE_AVAIL/mb-wp-ssl.conf"
    else
        sed -i '/^Listen 8080$/d' /etc/apache2/ports.conf 2>/dev/null || true
        wp_apache_name "$cert"
        if [ "$cert" = 1 ]; then
            wp_apache_ssl
            a2ensite mb-wp-ssl >/dev/null 2>&1
        else
            a2dissite mb-wp-ssl >/dev/null 2>&1 || true
            rm -f "$APACHE_AVAIL/mb-wp-ssl.conf"
        fi
    fi
    a2ensite mb-wp >/dev/null 2>&1

    if ! out=$(apachectl configtest 2>&1); then
        err "Apache configtest failed:"; printf '%s\n' "$out"; return 1
    fi
    # Без restart: он гонится со старым мастером за :80 (EADDRINUSE).
    # graceful — если Apache работает (и перечитывает новый Listen),
    # иначе старт с ретраями, пока старый процесс отдаёт порт.
    for i in 1 2 3; do
        if apache_running; then
            out=$(apachectl graceful 2>&1) && break
            warn "Apache graceful failed (attempt $i): $out"
        else
            out=$(apachectl start 2>&1) && break
            warn "Apache start failed (attempt $i), port may still be releasing: $out"
        fi
        sleep 2
    done
    if ! apache_running; then
        err "Apache is NOT running after apply. Diagnostics:"
        apachectl start 2>&1 | head -5
        return 1
    fi
}

do_reload_ssl() {
    [ -f "$ENV_FILE" ] && . "$ENV_FILE"
    [ "${WP_MODE:-name}" = name ] || return 0
    [ -s "$SSL_DIR/fullchain.pem" ] || return 0
    wp_apache_apply name 1
    wp_set_urls "https://$WP_DOMAIN"
    log "SSL reloaded, WP URLs -> https://$WP_DOMAIN"
}

wp_acme() {
    if [ "${WP_ACME:-1}" != "1" ]; then log "ACME skipped (WP_ACME=0)."; return 0; fi
    case "$WP_DOMAIN" in
        *.local|*.test|*.localhost|*.internal|*.example|*.invalid|localhost|"")
            log "ACME skipped: non-public domain '$WP_DOMAIN'."; return 0;;
    esac
    mkdir -p "$ACME_HOME"
    local args=(-d "$WP_DOMAIN")
    [ -n "$APEX" ] && args+=(-d "$APEX")
    if "$ACME_BIN" --home "$ACME_HOME" --issue --server letsencrypt "${args[@]}" \
        -w /var/www/letsencrypt --keylength 2048; then
        "$ACME_BIN" --home "$ACME_HOME" --install-cert -d "$WP_DOMAIN" \
            --key-file "$SSL_DIR/privkey.pem" \
            --fullchain-file "$SSL_DIR/fullchain.pem" \
            --reloadcmd "bash /opt/wp-setup.sh reload-ssl"
        chmod 600 "$SSL_DIR/privkey.pem" 2>/dev/null || true
        do_reload_ssl
        log "ACME certificate issued/installed."
    else
        warn "ACME issue failed (DNS/NAT not ready?). Serving HTTP; cron will retry."
    fi
}

wp_cron() {
    cat > /etc/cron.d/mikrobill-acme <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * * root flock -n /var/lock/mikrobill-acme.lock /root/.acme.sh/acme.sh --home /mikrobill-data/acme --cron --server letsencrypt >> /mikrobill-data/acme-renew.log 2>&1
EOF
    chmod 644 /etc/cron.d/mikrobill-acme
    service cron start >/dev/null 2>&1 || cron >/dev/null 2>&1 || true
    log "ACME renew cron installed (daily 03:17)."
}

main() {
    [ "${ENABLE_WP:-0}" = "1" ] || return 0
    if [ ! -f "$WP_INSTALLERS/BUNDLE_HASH" ]; then
        err "WP-bundle missing in image ($WP_INSTALLERS). Skipping WordPress."
        return 1
    fi
    wp_prepare || return 1

    local prev_domain prev_mode
    prev_domain=$(sed -n "s/^WP_DOMAIN=//p" "$STATE_FILE" 2>/dev/null | tr -d "'")
    prev_mode=$(sed -n "s/^WP_MODE=//p" "$STATE_FILE" 2>/dev/null | tr -d "'")
    if [ "$prev_mode" != "$MODE" ] || [ "$prev_domain" != "${WP_DOMAIN:-}" ]; then
        log "WP config changed: mode '${prev_mode:-?}'->'$MODE', domain '${prev_domain:-?}'->'${WP_DOMAIN:-?}'"
    fi

    local cert=0
    [ "$MODE" = name ] && [ -s "$SSL_DIR/fullchain.pem" ] && cert=1
    wp_apache_apply "$MODE" "$cert" || warn "Apache vhost apply had errors"

    local image_hash applied_hash
    image_hash=$(cat "$WP_INSTALLERS/BUNDLE_HASH")
    applied_hash=$(cat "$WP_DATA/.mb-bundle-hash" 2>/dev/null || echo "")

    if [ -f "$WP_DIR/wp-config.php" ] && WPCLI core is-installed >/dev/null 2>&1; then
        if [ "$image_hash" != "$applied_hash" ]; then
            if wp_upgrade; then
                wp_perms
                printf '%s' "$image_hash" > "$WP_DATA/.mb-bundle-hash"
            else
                err "WordPress upgrade FAILED — MikroBILL continues."
            fi
        else
            log "WP-bundle hash unchanged ($image_hash) — no upgrade."
            wp_perms
        fi
    else
        if wp_first_install; then
            wp_perms
            printf '%s' "$image_hash" > "$WP_DATA/.mb-bundle-hash"
        else
            err "WordPress first install FAILED — MikroBILL continues."
        fi
    fi

    wp_set_urls "$BASE"
    [ "$MODE" = name ] && wp_acme
    wp_cron

    cat > "$STATE_FILE" <<EOF
WP_DOMAIN='${WP_DOMAIN:-}'
WP_MODE='$MODE'
EOF
    if [ "$MODE" = port ]; then
        log "WordPress ready (PORT mode): $BASE  (service network only, 8080 not published)."
    else
        log "WordPress ready (NAME mode): $BASE  admin-net: $REQ_IP."
    fi
}

case "${1:-}" in
    reload-ssl) do_reload_ssl ;;
    *) main ;;
esac
