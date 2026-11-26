#!/bin/bash

# ==============================================================================
# MikroBILL container external entrypoint orchestrator
#
# Этот файл является точкой входа. Он не содержит бизнес-логики, только:
# 01. Передача управления внешнему entrypoint, если он лежит на диске.
# 02. Строгий режим оболочки.
# 03. Однократное включение логирования.
# 04. Определение каталога с модулями.
# 05. Подключение общего модуля.
# 06. Последовательный запуск модулей.
# ==============================================================================

# ------------------------------------------------------------------------------
# 01. Если этот файл лежит на примонтированном диске, встроенный entrypoint
#     должен передать управление сюда. Защита от повторного входа в себя.
# ------------------------------------------------------------------------------
if [ -f /mikrobill-data/entrypoint.sh ] && [ "${MB_ENTRYPOINT_EXTERNAL:-0}" != "1" ]; then
    echo "External entrypoint.sh found on mounted storage - using it"
    export MB_ENTRYPOINT_EXTERNAL=1
    exec bash /mikrobill-data/entrypoint.sh
fi

# ------------------------------------------------------------------------------
# 02. Строгий режим.
#     Не используем set -e, потому что часть команд может возвращать ненулевой
#     код в контейнерной среде, и мы обрабатываем ошибки вручную.
# ------------------------------------------------------------------------------
set -u

# ------------------------------------------------------------------------------
# 03. Однократное включение логирования.
#     Все модули наследуют этот поток вывода.
# ------------------------------------------------------------------------------
if [ "${MB_LOG_SET:-0}" != "1" ]; then
    export MB_LOG_SET=1
    mkdir -p /mikrobill-data
    exec > >(tee -a "/mikrobill-data/entrypoint.log") 2>&1
fi

echo "=== Entrypoint started at $(date) ==="

# ------------------------------------------------------------------------------
# 04. Каталог с модулями.
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${MB_MODULE_DIR:-}" ] && [ -d "${MB_MODULE_DIR}" ]; then
    MODULE_DIR="${MB_MODULE_DIR}"
elif [ -d "/mikrobill-data/modules" ]; then
    MODULE_DIR="/mikrobill-data/modules"
elif [ -d "${SCRIPT_DIR}/modules" ]; then
    MODULE_DIR="${SCRIPT_DIR}/modules"
elif [ -d "/opt/mikrobill-modules" ]; then
    MODULE_DIR="/opt/mikrobill-modules"
else
    echo "FATAL: module directory not found"
    exit 1
fi

# ------------------------------------------------------------------------------
# 05. Подключаем общие переменные и функции.
# ------------------------------------------------------------------------------
COMMON_MODULE="${MODULE_DIR}/00-common.sh"

if [ ! -f "$COMMON_MODULE" ]; then
    echo "FATAL: common module not found: $COMMON_MODULE"
    exit 1
fi

# shellcheck source=./modules/00-common.sh
source "$COMMON_MODULE"

# ------------------------------------------------------------------------------
# 06. Последовательный запуск модулей.
#     Каждый модуль должен быть source-able, то есть выполняться в текущей
#     оболочке и иметь доступ к общим переменным.
# ------------------------------------------------------------------------------
MODULES=(
    "01-system-shims.sh"
    "02-bind-mounts.sh"
    "03-secrets.sh"
    "04-mariadb.sh"
    "05-web.sh"
    "06-mikrobill-install.sh"
    "07-mikrobill-supervisor.sh"
)

for module_name in "${MODULES[@]}"; do
    module_path="${MODULE_DIR}/${module_name}"

    if [ ! -f "$module_path" ]; then
        echo "FATAL: module not found: $module_path"
        exit 1
    fi

    echo "--- Loading module: ${module_name} ---"

    # shellcheck disable=SC1090
    source "$module_path"
done

# Сюда выполнение обычно не доходит, потому что 07-mikrobill-supervisor.sh
# содержит бесконечный цикл супервизора.
echo "=== Entrypoint finished unexpectedly ==="
exit 1
