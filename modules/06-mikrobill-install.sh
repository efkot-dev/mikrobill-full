#!/bin/bash

# ==============================================================================
# 06-mikrobill-install.sh
#
# Обнаружение установленной версии, подготовка установщика и silent install.
#
# Блоки:
# 01. Определение установленного канала.
# 02. Проверка, нужна ли установка или восстановление.
# 03. Подготовка установщика stable/beta.
# 04. Предварительное создание web-каталогов.
# 05. Silent install.
# 06. Копирование web-файлов и прав.
# 07. Финальная проверка ядра.
# ==============================================================================

# ------------------------------------------------------------------------------
# 01. Определение установленного канала.
# ------------------------------------------------------------------------------
INSTALLED_CHANNEL=$(cat /var/MikroBILL/mb_channel 2>/dev/null || echo "unknown")

# ------------------------------------------------------------------------------
# 02. Проверка, нужна ли установка или восстановление.
#
# Linux-версия MikroBILL использует /var/MikroBILL/MikroBILL.xml,
# поэтому проверяем именно этот путь.
# ------------------------------------------------------------------------------
NEED_INSTALL=0

if [ ! -f /var/MikroBILL/bin/MikroBILL.dll ]; then
    echo "MikroBILL.dll is missing in /var/MikroBILL/bin"
    NEED_INSTALL=1
fi

if [ ! -f /var/MikroBILL/MikroBILL.xml ]; then
    echo "MikroBILL.xml is missing in /var/MikroBILL"
    NEED_INSTALL=1
fi

# ------------------------------------------------------------------------------
# 03. Подготовка установщика.
# ------------------------------------------------------------------------------
if [ "$NEED_INSTALL" = "1" ]; then
    echo "Install/repair required. Selected MikroBILL version: $MB_VERSION"

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
    echo "MikroBILL already installed (channel: $INSTALLED_CHANNEL)"

    if [ "$INSTALLED_CHANNEL" != "unknown" ] && [ "$INSTALLED_CHANNEL" != "$MB_VERSION" ]; then
        echo "NOTE: MB_VERSION=$MB_VERSION differs from installed channel; channel applies only to a fresh install"
    fi
fi

# ------------------------------------------------------------------------------
# 04. Предварительное создание web-каталогов.
#
# MikroBILL/installer может пытаться делать chmod на эти каталоги.
# Если их нет, в логе появляются ошибки вида:
# chmod: cannot access '/var/www/html/payin': No such file or directory
# ------------------------------------------------------------------------------
mkdir -p "$WEB_DIR"/payin "$WEB_DIR"/actionin "$WEB_DIR"/news "$WEB_DIR"/tvin
chmod -R a=rwx "$WEB_DIR"/payin "$WEB_DIR"/actionin "$WEB_DIR"/news "$WEB_DIR"/tvin 2>/dev/null || true

# ------------------------------------------------------------------------------
# 05. Silent install.
# ------------------------------------------------------------------------------
if [ "$NEED_INSTALL" = "1" ]; then
    if [ ! -f "$INSTALL_DIR/MikroBILL.dll" ]; then
        echo "FATAL: installer MikroBILL.dll not found"
        exit 1
    fi

    echo "First run or repair: installing MikroBILL ($MB_VERSION)..."

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

    dotnet "$INSTALL_DIR/MikroBILL.dll" /SILENT_INSTALL="$INSTALL_JSON" || INSTALL_RC=$?

    echo "Silent install finished with rc=$INSTALL_RC"

    if [ -f /var/MikroBILL/bin/MikroBILL.dll ]; then
        printf '%s' "$MB_VERSION" > /var/MikroBILL/mb_channel
    else
        echo "FATAL: MikroBILL silent install did not produce /var/MikroBILL/bin/MikroBILL.dll"
        exit 1
    fi

    sleep 5
fi

# ------------------------------------------------------------------------------
# 06. Копирование web-файлов и прав.
# ------------------------------------------------------------------------------
if [ -d /var/MikroBILL/bin/web ] && [ ! -f "${WEB_DIR}/web.ver" ]; then
    cp -rT /var/MikroBILL/bin/web "${WEB_DIR}" || true
fi

mkdir -p "$WEB_DIR"/payin "$WEB_DIR"/actionin "$WEB_DIR"/news "$WEB_DIR"/tvin

for d in payin actionin news tvin; do
    mkdir -p "${WEB_DIR}/$d"
    chmod -R a=rwx "${WEB_DIR}/$d" 2>/dev/null || true
done

chown -R www-data:www-data "${WEB_DIR}" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 07. Финальная проверка ядра.
# ------------------------------------------------------------------------------
if [ ! -f /var/MikroBILL/bin/MikroBILL.dll ]; then
    echo "FATAL: installed core not found"
    exit 1
fi
