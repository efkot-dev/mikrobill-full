#!/bin/bash

# ==============================================================================
# 04-mariadb.sh
#
# Инициализация и запуск MariaDB внутри контейнера.
#
# Блоки:
# 01. Настройка конфигурации MariaDB.
# 02. Инициализация datadir при первом запуске.
# 03. Запуск mysqld_safe.
# 04. Ожидание готовности MySQL.
# 05. Применение SQL-прав и создание базы.
# 06. Автоматическое восстановление поврежденных таблиц.
# ==============================================================================

# ------------------------------------------------------------------------------
# 01. Настройка конфигурации MariaDB.
#
# Нужно, чтобы MySQL слушал не только localhost, и чтобы не использовался
# binary log, который в контейнере обычно не нужен.
# ------------------------------------------------------------------------------
CNF=/etc/mysql/mariadb.conf.d/50-server.cnf

if [ -f "$CNF" ] && ! grep -q '^skip-name-resolve' "$CNF"; then
    sed -i 's/^bind-address\s*=.*/bind-address = 0.0.0.0/' "$CNF"
    sed -i '/^\[mysqld\]/a skip-log-bin\nskip-name-resolve' "$CNF"
fi

# ------------------------------------------------------------------------------
# 02. Инициализация datadir.
# ------------------------------------------------------------------------------
if [ ! -d /var/lib/mysql/mysql ]; then
    echo "Initializing MariaDB..."

    if command -v mariadb-install-db >/dev/null 2>&1; then
        mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null
    else
        mysql_install_db --user=mysql --datadir=/var/lib/mysql >/dev/null
    fi
fi

# ------------------------------------------------------------------------------
# 03. Запуск mysqld_safe.
# ------------------------------------------------------------------------------
mysqld_safe --skip-syslog &

# ------------------------------------------------------------------------------
# 04. Ожидание готовности.
# ------------------------------------------------------------------------------
for i in $(seq 1 30); do
    if mysqladmin ping --silent 2>/dev/null; then
        break
    fi

    sleep 2
done

# ------------------------------------------------------------------------------
# 05. Применение SQL-прав.
# ------------------------------------------------------------------------------
DB_USER_SQL=$(sql_escape "$DB_USER")
DB_PASS_SQL=$(sql_escape "$DB_PASSWORD")
DB_NAME_SQL=$(sql_escape "$DB_NAME")

mysql -uroot <<SQL || true
-- Очистка анонимных пользователей во избежание конфликтов прав
DELETE FROM mysql.user WHERE user = '';
DELETE FROM mysql.user WHERE user = 'PUBLIC';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';

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

-- Root для локальных служебных проверок
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '';
ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;

FLUSH PRIVILEGES;
SQL

# ------------------------------------------------------------------------------
# 06. Автоматическое восстановление таблиц.
# ------------------------------------------------------------------------------
echo "Checking and repairing database tables..."
mysqlcheck -uroot --auto-repair --all-databases 2>/dev/null || true
