# MikroBILL All-in-One Docker Image

Полностью контейнеризованная версия MikroBILL для запуска на MikroTik RouterOS 7 (x86/CHR) или любом другом Docker-хосте.
Внутри одного образа собрано всё необходимое: MariaDB, Apache 2.4, PHP, .NET 6, acme.sh (Let's Encrypt) и само ядро MikroBILL.

Образ автоматически пересобирается GitHub Actions при выходе новых версий на сайте разработчика и публикуется в Docker Hub с тегом в формате `DDMMYYYY` (по дате модификации бинарного файла).

---

## Системные требования

Ориентированы на официальную инструкцию, но с учетом оверхеда Docker:

| | Минимальные | Рекомендуемые |
|---|---|---|
| **ОС** | UNIX / RouterOS 7 (x86) | UNIX / RouterOS 7 (x86) |
| **RAM** | 2GB | 8GB |
| **Диск** | 15GB (SSD/HDD) | 120GB (SSD) |

*Внутри контейнера уже настроены: Apache 2.4, PHP (со всеми требуемыми модулями: curl, mbstring, xml, gmp, pdo_mysql), MariaDB и OpenSSL.*

---

## 🚀 Быстрый старт (Скрипт для MikroTik RouterOS 7)

Этот скрипт автоматически создаст папки на диске, настроит виртуальный сетевой интерфейс (veth), добавит его в bridge, создаст точки монтирования, переменные окружения, NAT-правила для проброса портов и запустит контейнер.

**Инструкция:**
1. Откройте **New Terminal** в WinBox или WebFig.
2. Скопируйте код ниже.
3. **ОБЯЗАТЕЛЬНО** измените значения в блоке `НАСТРОЙКИ` (имя диска, IP-адреса, пароли, домен и ваш логин Docker Hub).
4. Вставьте в терминал и нажмите `Enter`.

```routeros
# ==========================================
# MikroBILL Docker Installation Script
# ==========================================

# --- НАСТРОЙКИ (ИЗМЕНИТЕ ПОД СЕБЯ) ---
:global diskName "disk1"
:global baseDir "$diskName/mikrobill"

:global containerName "mikrobill"
:global containerIP "192.168.88.10"
:global containerMask "24"
:global containerGW "192.168.88.1"
:global bridgeName "bridge"

# Укажите ваш образ из Docker Hub (или конкретный тег, например :04102026)
:global dockerImage "YOUR_DOCKERHUB_USERNAME/mikrobill-full:latest"

:global dbPassword "CHANGE_ME_DB_PASSWORD"
:global adminPassword "CHANGE_ME_ADMIN_PASSWORD"

:global acmeDomain "billing.example.com"
:global acmeEmail "admin@example.com"
# --------------------------------------

:put "Создание директорий на диске $diskName..."
/file mkdir "$baseDir"
/file mkdir "$baseDir/mysql"
/file mkdir "$baseDir/data"
/file mkdir "$baseDir/web"

:put "Настройка сети (VETH и Bridge)..."
/interface veth add name="veth-$containerName" address="$containerIP/$containerMask" gateway="$containerGW"
/interface bridge port add bridge="$bridgeName" interface="veth-$containerName"

:put "Настройка точек монтирования (Mounts)..."
/container mounts add name="$containerName-mysql" src="$baseDir/mysql" dst="/var/lib/mysql"
/container mounts add name="$containerName-data" src="$baseDir/data" dst="/var/MikroBILL"
/container mounts add name="$containerName-web" src="$baseDir/web" dst="/var/www/html"

:put "Настройка переменных окружения..."
/container envs add name="$containerName" key="DB_NAME" value="mikrobill"
/container envs add name="$containerName" key="DB_USER" value="mikrobill"
/container envs add name="$containerName" key="DB_PASSWORD" value="$dbPassword"
/container envs add name="$containerName" key="ADMIN_LOGIN" value="admin"
/container envs add name="$containerName" key="ADMIN_PASSWORD" value="$adminPassword"
/container envs add name="$containerName" key="ACME_DOMAIN" value="$acmeDomain"
/container envs add name="$containerName" key="ACME_EMAIL" value="$acmeEmail"

:put "Создание и запуск контейнера..."
/container add remote-image="$dockerImage" name="$containerName" interface="veth-$containerName" envlist="$containerName" mounts="$containerName-mysql,$containerName-data,$containerName-web" logging=yes

:put "Настройка Firewall NAT (Проброс портов)..."
/ip firewall nat add chain=dstnat protocol=tcp dst-port=80 action=dst-nat to-addresses="$containerIP" to-ports=80 comment="MikroBILL HTTP"
/ip firewall nat add chain=dstnat protocol=tcp dst-port=443 action=dst-nat to-addresses="$containerIP" to-ports=443 comment="MikroBILL HTTPS"
/ip firewall nat add chain=dstnat protocol=tcp dst-port=7402-7405 action=dst-nat to-addresses="$containerIP" comment="MikroBILL Core"

:put "✅ Готово! Контейнер запускается."
:put "Проверьте статус командой: /container print"
:put "Логи: /container log mikrobill"
```

---

## 🗑 Скрипт полного удаления (Uninstall)

Если вам нужно пересобрать контейнер с нуля или удалить биллинг, используйте этот скрипт. Он безопасно удалит контейнер, интерфейсы, правила фаервола и настройки, **не трогая ваши данные на диске** (`disk1/mikrobill/`).

```routeros
:global containerName "mikrobill"

:put "Остановка и удаление контейнера..."
/container remove [find name="$containerName"]

:put "Удаление переменных окружения..."
/container envs remove [find name="$containerName"]

:put "Удаление точек монтирования..."
/container mounts remove [find name~"$containerName"]

:put "Удаление сетевого интерфейса veth..."
/interface veth remove [find name="veth-$containerName"]

:put "Удаление правил NAT..."
/ip firewall nat remove [find comment~"MikroBILL"]

:put "✅ Контейнер и настройки удалены. Данные на диске сохранены."
```

---

## 🔄 Обновление версии

GitHub Actions автоматически собирает новые версии и пушит их в Docker Hub с тегом в формате `DDMMYYYY` (например, `04102026`).

Чтобы обновить MikroBILL на роутере до новой версии:
1. Посмотрите доступные теги в вашем репозитории на Docker Hub.
2. Измените параметр `remote-image` в настройках контейнера:

```routeros
/container set mikrobill remote-image=YOUR_DOCKERHUB_USERNAME/mikrobill-full:04102026
/container start mikrobill
```

---

## 🔐 Где найти сгенерированные пароли?

Если вы **не задали** `DB_PASSWORD` или `ADMIN_PASSWORD` в скрипте установки, контейнер сгенерирует их сам при первом запуске и сохранит на диск.

Вы можете прочитать их через терминал RouterOS:

```routeros
# Пароль от базы данных MariaDB
/file print file=disk1/mikrobill/data/secrets/db_password

# Пароль от админки MikroBILL
/file print file=disk1/mikrobill/data/secrets/admin_password
```
*(Файлы будут экспортированы в корень диска, их можно открыть через WinBox или скачать по SMB/FTP).*

---

## 📂 Структура данных на диске

Все критически важные данные хранятся на вашем диске (например, `disk1`):

| Путь на RouterOS | Что хранит |
|---|---|
| `disk1/mikrobill/mysql` | База данных MariaDB (таблицы, пользователи) |
| `disk1/mikrobill/data` | Конфиг `MikroBILL.xml`, секреты, SSL-сертификаты Let's Encrypt |
| `disk1/mikrobill/web` | PHP-файлы веб-интерфейса (копируются из ядра при первом старте) |

Для резервного копирования достаточно регулярно копировать папку `disk1/mikrobill`.

---

## 🌐 SSL и Let's Encrypt (ACMEv2)

Если в скрипте вы указали `acmeDomain` (например, `billing.example.com`), контейнер автоматически попытается выпустить SSL-сертификат через HTTP-01 challenge.

**Требования для успешного выпуска:**
1. Домен должен смотреть публичным IP на ваш MikroTik.
2. Порт `80` из интернета должен быть проброшен на IP контейнера (скрипт выше это делает автоматически).
3. Порт `80` не должен быть занят веб-интерфейсом самого RouterOS (перенесите WinBox/WebFig на другие порты, например 8080/8443).

Если порт 80 открыть нельзя, используйте DNS-01 challenge (например, через Cloudflare). Для этого добавьте переменные в скрипт установки:
```routeros
/container envs add name="mikrobill" key="ACME_DNS" value="dns_cf"
/container envs add name="mikrobill" key="CF_Token" value="YOUR_TOKEN"
/container envs add name="mikrobill" key="CF_Account_ID" value="YOUR_ID"
```

---

## 📡 Порты

| Порт | Назначение |
|---|---|
| `80` | HTTP / ACME HTTP-01 challenge |
| `443` | HTTPS (Веб-интерфейс) |
| `7402-7405` | Ядро MikroBILL / MikroREMOTE |
