#!/bin/bash

# ==============================================================================
# 07-mikrobill-supervisor.sh
#
# Супервизор процесса MikroBILL.
#
# Блоки:
# 01. Инициализация состояния супервизора.
# 02. Обработка сигналов остановки контейнера.
# 03. Основной цикл супервизора.
# 04. Обработка явной остановки сервиса.
# 05. Запуск ядра MikroBILL.
# 06. Анализ причины завершения.
# 07. Перезапуск с паузой.
# ==============================================================================

# ------------------------------------------------------------------------------
# 01. Инициализация состояния супервизора.
# ------------------------------------------------------------------------------
MB_PID=""

# ------------------------------------------------------------------------------
# 02. Обработка сигналов остановки контейнера.
# ------------------------------------------------------------------------------
request_container_stop() {
    echo "Signal received, stopping container entrypoint"

    touch "$CONTAINER_STOP_FLAG"
    touch "$STOP_FLAG"

    if [ -n "${MB_PID:-}" ]; then
        kill -TERM "$MB_PID" 2>/dev/null || true
    fi
}

trap request_container_stop TERM INT

# ------------------------------------------------------------------------------
# 03. Основной цикл супервизора.
# ------------------------------------------------------------------------------
while true; do
    if [ -f "$CONTAINER_STOP_FLAG" ]; then
        echo "Container stop flag set, exiting entrypoint"
        exit 0
    fi

    # --------------------------------------------------------------------------
    # 04. Обработка явной остановки сервиса.
    #
    # Если кто-то выполнил systemctl stop mikrobill, ждем systemctl start.
    # --------------------------------------------------------------------------
    if [ -f "$STOP_FLAG" ]; then
        echo "MikroBILL service stopped by request. Waiting for 'systemctl start mikrobill'..."

        rm -f "$STOP_FLAG" "$RESTART_FLAG"

        while [ ! -f "$START_FLAG" ] && [ ! -f "$CONTAINER_STOP_FLAG" ]; do
            sleep 2
        done

        if [ -f "$CONTAINER_STOP_FLAG" ]; then
            echo "Container stop flag set while service was stopped, exiting entrypoint"
            exit 0
        fi

        rm -f "$START_FLAG"
    fi

    rm -f "$RESTART_FLAG" "$STOP_FLAG" "$START_FLAG"

    START_TS=$(date +%s)

    # --------------------------------------------------------------------------
    # 05. Запуск ядра MikroBILL.
    # --------------------------------------------------------------------------
    echo "Starting: dotnet /var/MikroBILL/bin/MikroBILL.dll /SERVER"

    dotnet /var/MikroBILL/bin/MikroBILL.dll /SERVER &
    MB_PID=$!

    echo "$MB_PID" > "$PIDFILE"

    wait "$MB_PID"
    RC=$?

    MB_PID=""
    rm -f "$PIDFILE"

    END_TS=$(date +%s)
    RUNTIME=$((END_TS - START_TS))

    # --------------------------------------------------------------------------
    # 06. Анализ причины завершения.
    # --------------------------------------------------------------------------
    if [ -f "$CONTAINER_STOP_FLAG" ]; then
        echo "Container stop flag set after MikroBILL exit, exiting entrypoint"
        exit 0
    fi

    if [ -f "$RESTART_FLAG" ]; then
        echo "MikroBILL restart requested via systemctl shim; restarting process..."
        rm -f "$RESTART_FLAG"
        sleep 2
        continue
    fi

    if [ -f "$STOP_FLAG" ]; then
        echo "MikroBILL stop requested via systemctl shim"
        continue
    fi

    # --------------------------------------------------------------------------
    # 07. Перезапуск с паузой.
    # --------------------------------------------------------------------------
    echo "MikroBILL exited with rc=$RC after ${RUNTIME}s; restarting in 5s"
    sleep 5
done
