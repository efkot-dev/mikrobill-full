# MikroBILL All-in-One Docker Image

Полностью контейнеризованная версия MikroBILL для запуска на MikroTik RouterOS 7 x86 или любом другом Docker-хосте.

Внутри одного образа:

- MariaDB
- Apache 2.4
- PHP
- .NET 6
- acme.sh / Let's Encrypt
- MikroBILL

---

## Системные требования

Для комфортной работы лучше ориентироваться на рекомендуемые требования:

- ОС: UNIX / Docker host
- RAM: 8GB
- SSD: 120GB

Минимально производитель заявляет:

- RAM: 1GB
- HDD: 10GB

Но для Docker-варианта с MariaDB, Apache, PHP и .NET лучше иметь запас по памяти и диску.

---

## Переменные окружения

Задаются через `/container envs` в RouterOS или через `-e` в обычном Docker.

| Переменная | Описание | По умолчанию |
|---|---|---|
| `DB_NAME` | Имя базы данных | `mikrobill` |
| `DB_USER` | Пользователь базы данных | `mikrobill` |
| `DB_PASSWORD` | Пароль базы данных. Если не задан, будет сгенерирован автоматически | auto |
| `ADMIN_LOGIN` | Логин администратора MikroBILL | `admin` |
| `ADMIN_PASSWORD` | Пароль администратора. Если не задан, будет сгенерирован автоматически | auto |
| `ACME_DOMAIN` | Домен для выпуска SSL-сертификата | пусто |
| `ACME_EMAIL` | Email для Let's Encrypt | `admin@example.com` |
| `ACME_STAGING` | Использовать тестовый Let's Encrypt staging. Значение: `yes` или `no` | `no` |
| `ACME_FORCE` | Принудительно перевыпустить сертификат. Значение: `yes` или `no` | `no` |
| `ACME_DNS` | DNS-провайдер для acme.sh, например `dns_cf` для Cloudflare | пусто |

---

## Где хранятся пароли

Если пароль не задан через переменную окружения, он генерируется при первом старте и сохраняется внутри persistent-тома:

```text
/var/MikroBILL/secrets/db_password
/var/MikroBILL/secrets/admin_password
```

При использовании монтирования в RouterOS это будет примерно:

```text
disk1/mikrobill/data/secrets/db_password
disk1/mikrobill/data/secrets/admin_password
```

---

## Точки монтирования

Для нормальной работы контейнера обязательно нужно сохранить данные на внешнем томе.

| Путь внутри контейнера | Назначение |
|---|---|
| `/var/lib/mysql` | База данных MariaDB |
| `/var/MikroBILL` | Конфигурация, секреты, сертификаты, данные MikroBILL |
| `/var/www/html` | WEB-файлы, PHP-интерфейс, ACME webroot |

---

## Пример настройки в MikroTik RouterOS 7

### 1. Создать каталоги

```routeros
/file mkdir disk1/mikrobill
/file mkdir disk1/mikrobill/mysql
/file mkdir disk1/mikrobill/data
/file mkdir disk1/mikrobill/web
```

### 2. Создать mounts

```routeros
/container mounts add name=mikrobill-mysql src=disk1/mikrobill/mysql dst=/var/lib/mysql
/container mounts add name=mikrobill-data src=disk1/mikrobill/data dst=/var/MikroBILL
/container mounts add name=mikrobill-web src=disk1/mikrobill/web dst=/var/www/html
```

### 3. Создать переменные окружения

```routeros
/container envs add name=mikrobill key=DB_NAME value=mikrobill
/container envs add name=mikrobill key=DB_USER value=mikrobill
/container envs add name=mikrobill key=DB_PASSWORD value=CHANGE_ME_DB_PASSWORD

/container envs add name=mikrobill key=ADMIN_LOGIN value=admin
/container envs add name=mikrobill key=ADMIN_PASSWORD value=CHANGE_ME_ADMIN_PASSWORD

/container envs add name=mikrobill key=ACME_DOMAIN value=billing.example.com
/container envs add name=mikrobill key=ACME_EMAIL value=admin@example.com
```

### 4. Добавить контейнер

```routeros
/container add remote-image=YOUR_DOCKERHUB_USERNAME/mikrobill-full:latest \
    name=mikrobill \
    interface=veth-mikrobill \
    envlist=mikrobill \
    mounts=mikrobill-mysql,mikrobill-data,mikrobill-web
```

---

## Порты

Обычно используются:

| Порт | Назначение |
|---|---|
| `80` | HTTP / ACME HTTP-01 challenge |
| `443` | HTTPS |
| `7402-7405` | Ядро MikroBILL / MikroREMOTE |

---

## SSL / ACME

Если задать:

```text
ACME_DOMAIN=billing.example.com
ACME_EMAIL=admin@example.com
```

контейнер попытается выпустить сертификат Let's Encrypt через HTTP-01.

Для этого нужно:

1. Домен должен указывать на публичный IP MikroTik.
2. Порт `80` должен быть проброшен в контейнер.
3. Порт `80` не должен конфликтовать с веб-интерфейсом самого RouterOS.

Если порт `80` открыть нельзя, можно использовать DNS-01 через `ACME_DNS`.

Например, для Cloudflare:

```routeros
/container envs add name=mikrobill key=ACME_DNS value=dns_cf
/container envs add name=mikrobill key=CF_Token value=YOUR_CLOUDFLARE_TOKEN
/container envs add name=mikrobill key=CF_Account_ID value=YOUR_CLOUDFLARE_ACCOUNT_ID
```

---

## Обновление

Проект использует GitHub Actions.

Workflow по расписанию:

1. Скачивает архив MikroBILL.
2. Определяет дату бинарного файла внутри архива.
3. Делает тег вида `DDMMYYYY`, например `04102026`.
4. Если такого тега еще нет в Docker Hub, собирает и публикует образ.
5. Создает GitHub Release с архивом.

Примеры тегов:

```text
YOUR_DOCKERHUB_USERNAME/mikrobill-full:latest
YOUR_DOCKERHUB_USERNAME/mikrobill-full:04102026
```

---

## Резервное копирование

Достаточно регулярно копировать три каталога:

```text
disk1/mikrobill/mysql
disk1/mikrobill/data
disk1/mikrobill/web
```

В них находятся:

- база данных;
- конфигурация MikroBILL;
- секреты;
- SSL-сертификаты;
- WEB-файлы.
