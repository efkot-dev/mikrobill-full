#!/bin/bash

# ==============================================================================
# 00-common.sh
#
# Общие переменные и функции для всех модулей.
# Этот файл подключается через source и не должен запускаться отдельно.
#
# Блоки:
# 01. Общие каталоги.
# 02. Переменные базы данных и администратора.
# 03. Флаги управления процессом MikroBILL.
# 04. Вспомогательные функции.
# ==============================================================================

# ------------------------------------------------------------------------------
# 01. Общие каталоги.
# ------------------------------------------------------------------------------
WEB_DIR="${WEB_DIR:-/var/www/html}"
SECRET_DIR="${SECRET_DIR:-/mikrobill-data/secrets}"
INSTALL_DIR="${INSTALL_DIR:-/opt/mikrobill-installer}"

DATA_DIR="${DATA_DIR:-/mikrobill-data/data}"
MYSQL_DIR="${MYSQL_DIR:-/mikrobill-data/mysql}"
WEB_DATA_DIR="${WEB_DATA_DIR:-/mikrobill-data/web}"

# ------------------------------------------------------------------------------
# 02. Переменные базы данных и администратора.
# ------------------------------------------------------------------------------
DB_NAME="${DB_NAME:-mikrobill}"
DB_USER="${DB_USER:-mikrobill}"
ADMIN_LOGIN="${ADMIN_LOGIN:-Admin}"
MB_VERSION="${MB_VERSION:-stable}"

# ------------------------------------------------------------------------------
# 03. Флаги управления процессом MikroBILL.
#     Используются systemctl shim и супервизором.
# ------------------------------------------------------------------------------
RESTART_FLAG="${RESTART_FLAG:-/var/run/mikrobill.restart}"
STOP_FLAG="${STOP_FLAG:-/var/run/mikrobill.stop}"
START_FLAG="${START_FLAG:-/var/run/mikrobill.start}"
CONTAINER_STOP_FLAG="${CONTAINER_STOP_FLAG:-/var/run/mikrobill.container-stop}"
PIDFILE="${PIDFILE:-/var/run/mikrobill.pid}"

# ------------------------------------------------------------------------------
# 04. Вспомогательные функции.
# ------------------------------------------------------------------------------

# Проверяет, является ли путь точкой монтирования.
is_mounted() {
    local path="$1"

    if mountpoint -q "$path" 2>/dev/null; then
        return 0
    fi

    awk -v d="$path" '$2 == d {found=1} END {exit !found}' /proc/mounts 2>/dev/null
}

# Делает bind mount каталога.
# Если цель уже смонтирована, повторно не монтирует.
# Если цель является симлинком, удаляет симлинк.
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

# Экранирует одинарные кавычки для SQL.
sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}
