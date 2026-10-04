# MikroBILL All-in-One Docker Image

Полностью контейнеризованная версия MikroBILL для запуска на MikroTik RouterOS 7 (x86) или любом другом Docker-хосте.
Внутри одного образа: MariaDB, Apache 2.4, PHP, .NET 6, acme.sh (Let's Encrypt) и само ядро MikroBILL.

## Переменные окружения (Env)
Задаются через `/container envs` в RouterOS или `-e` в обычном Docker:

| Переменная | Описание | По умолчанию |
|---|---|---|
| `DB_NAME` | Имя базы данных | `mikrobill` |
| `DB_USER` | Пользователь БД | `mikrobill` |
| `DB_PASSWORD` | Пароль БД (если не задан, генерируется автоматически) | *авто* |
| `ADMIN_LOGIN` | Логин админа веб-интерфейса | `admin` |
| `ADMIN_PASSWORD` | Пароль админа веб-интерфейса (если не задан, генерируется) | *авто* |
| `ACME_DOMAIN` | Домен для выпуска SSL сертификата | *пусто* |
| `ACME_EMAIL` | Email для Let's Encrypt | `admin@example.com` |

## Точки монтирования (Volumes)
Критически важны для сохранения данных между перезапусками!

| Путь внутри | Куда монтировать в RouterOS | Что хранит |
|---|---|---|
| `/var/lib/mysql` | `disk1/mikrobill/mysql` | База данных MariaDB |
| `/var/MikroBILL` | `disk1/mikrobill/data` | Конфиги, секреты, SSL сертификаты |
| `/var/www/html` | `disk1/mikrobill/web` | PHP-файлы веб-интерфейса |

## Использование в MikroTik RouterOS 7
