#!/bin/bash

# ==============================================================================
#
# Устанавливает заглушки для systemd/dbus в контейнере без systemd.
#
# Блоки:
# 01. Создание умного systemctl shim.
# 02. Раскладка systemctl shim по всем стандартным путям.
# 03. Создание заглушек для dbus-утилит.
# 04. Завершение модуля.
# ==============================================================================

# ------------------------------------------------------------------------------
# 01. Создание умного systemctl shim.
#
# Он должен:
# - перехватывать apache/httpd команды и выполнять apachectl graceful/restart;
# - перехватывать mikrobill команды и управлять реальным процессом через флаги;
# - для status/is-active возвращать корректный код возврата;
# - для остальных сервисов молча возвращать успех.
# ------------------------------------------------------------------------------
mkdir -p /usr/local/bin

cat <<'SHIM_EOF' > /usr/local/bin/systemctl
#!/bin/bash

ARGS="$*"

RESTART_FLAG=/var/run/mikrobill.restart
STOP_FLAG=/var/run/mikrobill.stop
START_FLAG=/var/run/mikrobill.start
PIDFILE=/var/run/mikrobill.pid

APACHECTL=/usr/sbin/apachectl
if [ ! -x "$APACHECTL" ]; then
    APACHECTL=apachectl
fi

# ------------------------------------------------------------------------------
# Apache / httpd
# ------------------------------------------------------------------------------
if echo "$ARGS" | grep -qiE 'apache|httpd'; then
    case "${1:-}" in
        start)
            "$APACHECTL" start >/dev/null 2>&1 || true
            ;;
        stop)
            "$APACHECTL" stop >/dev/null 2>&1 || true
            ;;
        reload|reload-or-restart|try-restart|condrestart)
            "$APACHECTL" graceful >/dev/null 2>&1 || true
            ;;
        restart)
            "$APACHECTL" restart >/dev/null 2>&1 || "$APACHECTL" graceful >/dev/null 2>&1 || true
            ;;
        status|is-active|is-enabled|show)
            exit 0
            ;;
        *)
            exit 0
            ;;
    esac
    exit 0
fi

# ------------------------------------------------------------------------------
# MikroBILL
# ------------------------------------------------------------------------------
if echo "$ARGS" | grep -qiE 'mikrobill'; then
    get_pid() {
        cat "$PIDFILE" 2>/dev/null || true
    }

    is_running() {
        local pid
        pid=$(get_pid)

        if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi

        return 1
    }

    kill_mikrobill() {
        local pid
        pid=$(get_pid)

        if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            return 0
        fi

        # Fallback: если pidfile потерян, ищем процесс по cmdline.
        local p cmd
        for p in /proc/[0-9]*; do
            [ -r "$p/cmdline" ] || continue

            cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)

            case "$cmd" in
                *MikroBILL.dll*SERVER*)
                    kill -TERM "${p#/proc/}" 2>/dev/null || true
                    ;;
            esac
        done
    }

    case "${1:-}" in
        restart|reload|reload-or-restart|try-restart|condrestart)
            touch "$RESTART_FLAG" "$START_FLAG"
            rm -f "$STOP_FLAG"
            kill_mikrobill
            exit 0
            ;;
        stop)
            touch "$STOP_FLAG"
            rm -f "$START_FLAG" "$RESTART_FLAG"
            kill_mikrobill
            exit 0
            ;;
        start)
            if is_running; then
                exit 0
            fi

            touch "$START_FLAG"
            rm -f "$STOP_FLAG"
            exit 0
            ;;
        status|is-active|is-enabled|show)
            if is_running; then
                exit 0
            else
                exit 3
            fi
            ;;
        *)
            exit 0
            ;;
    esac
fi

# ------------------------------------------------------------------------------
# Все остальные сервисы: тихо делаем вид, что всё хорошо.
# ------------------------------------------------------------------------------
exit 0
SHIM_EOF

chmod +x /usr/local/bin/systemctl

# ------------------------------------------------------------------------------
# 02. Раскладка systemctl shim по всем стандартным путям.
#
# MikroBILL или внутренние скрипты могут вызывать systemctl не через PATH,
# а по абсолютному пути, поэтому заменяем все известные расположения.
# ------------------------------------------------------------------------------
for p in /usr/bin/systemctl /bin/systemctl /usr/sbin/systemctl /sbin/systemctl; do
    if [ -d "$(dirname "$p")" ]; then
        rm -f "$p"
        cp -f /usr/local/bin/systemctl "$p" 2>/dev/null || true
        chmod +x "$p" 2>/dev/null || true
    fi
done

# ------------------------------------------------------------------------------
# 03. Создание заглушек для dbus-утилит.
#
# Это убирает сообщения вида:
# Failed to connect to bus: Host is down
# ------------------------------------------------------------------------------
cat <<'DBUS_EOF' > /usr/local/bin/busctl
#!/bin/sh
exit 0
DBUS_EOF

chmod +x /usr/local/bin/busctl

for p in /usr/bin/busctl /bin/busctl; do
    if [ -d "$(dirname "$p")" ]; then
        rm -f "$p"
        cp -f /usr/local/bin/busctl "$p" 2>/dev/null || true
        chmod +x "$p" 2>/dev/null || true
    fi
done

cat <<'DBUS_EOF' > /usr/local/bin/dbus-send
#!/bin/sh
exit 0
DBUS_EOF

chmod +x /usr/local/bin/dbus-send

for p in /usr/bin/dbus-send /bin/dbus-send; do
    if [ -d "$(dirname "$p")" ]; then
        rm -f "$p"
        cp -f /usr/local/bin/dbus-send "$p" 2>/dev/null || true
        chmod +x "$p" 2>/dev/null || true
    fi
done

# ------------------------------------------------------------------------------
# 04. Завершение модуля.
# ------------------------------------------------------------------------------
echo "Smart systemctl/dbus shims installed."
