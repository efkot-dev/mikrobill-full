# MikroBILL в одном Docker-контейнере для MikroTik RouterOS 7

Внутри образа: MariaDB, Apache 2.4 + PHP, .NET 6, acme.sh, MikroBILL.
Единственная точка монтирования `/mikrobill-data`, логика старта — внешний
`entrypoint.sh` на диске роутера (правится без пересборки образа).

## Каналы: stable и beta

Образ один и тот же для обоих каналов, выбор — переменная `MB_VERSION`:
- `stable` (по умолчанию) — распакован при сборке в `/opt/mikrobill-installer`;
- `beta` — лежит в образе архивом `/opt/mikrobill-beta.zip`, распаковывается
  при первом старте контейнера.

Скриптовая установка (`SILENT_INSTALL`) одинакова для обоих каналов. Если
beta-архива в образе нет (образ собран до введения канала), `entrypoint.sh`
скачивает его с `https://mikro-bill.com/downloads/beta` — первый старт с beta
будет чуть дольше.

## Конфигуратор и генератор скриптов
**https://efkot-dev.github.io/mikrobill-full/** — заполняет поля и отдаёт готовые
`setup.rsc` / `uninstall.rsc` / `check.rsc` под ваш диск, IP, bridge, канал и пароли.
Экспорт копированием и файлом — всегда CRLF (RouterOS читает файлы как Windows-текст).

Доставка на роутер через приватный GitHub Gist: кнопка «Опубликовать в Gist» создаёт
все скрипты плюс `bootstrap.rsc`; роутер скачивает их голым HTTPS-запросом (`/tool/fetch`)
и регистрирует в System -> Scripts.

## Установка

**Способ A — ручной import:**
1. Сгенерируйте и скачайте `setup.rsc`.
2. Загрузите его в Files роутера (WinBox/FTP).
3. `/import file=setup.rsc`, логи: `/log print follow where topics~"container"`.

**Способ B — bootstrap через Gist (одной командой):**
1. В конфигураторе сгенерируйте скрипты и нажмите «Опубликовать в Gist».
2. Скопируйте появившуюся команду (3 строки: `/tool/fetch` + `/import` + `/file/remove`).
3. Вставьте её в терминал роутера — скрипты появятся в System -> Scripts,
   далее `/system/script/run mikrobill-setup`.

`check.rsc` — диагностика роутера (device-mode, clock, DNS, диск, bridge), ничего не меняет.

## Данные на диске (одна папка)
```text
<disk>/mikrobill/
├── entrypoint.sh   логика старта (правится на лету)
├── secrets/        db_password, admin_password
├── mysql/          MariaDB
├── data/           MikroBILL.xml, cert/
├── web/            PHP-часть
└── container/      root-dir (rootfs образа)
```

## Переменные окружения

| Переменная | Назначение | По умолчанию |
|---|---|---|
| `MB_VERSION` | канал: `stable` / `beta` | `stable` |
| `DB_NAME`, `DB_USER` | имя БД и пользователь | `mikrobill` |
| `DB_PASSWORD` | пароль БД (пусто = автогенерация, см. Пароли) | — |
| `ADMIN_LOGIN` | логин веб-админа | `Admin` |
| `ADMIN_PASSWORD` | пароль админа (пусто = автогенерация, см. Пароли) | — |
| `CONTAINER_IP`, `WEB_URL` | переопределение автоопределения IP / web-адреса | авто |

## Пароли
Задаются через поля генератора (ENV контейнера). Если поле пустое — пароль
генерируется при первом старте и лежит в `<disk>/mikrobill/secrets/`.

## Порты
80/443 — веб + ACME, 7402 — ядро/MikroREMOTE, 3306 — БД (NAT опционально,
не открывайте наружу без filter-правила).

## SSL
MikroBILL сам выпускает сертификаты через встроенный acme.sh; нужен проброс
80 порта и свободный от www RouterOS порт 80 (`/ip service set www disabled=yes`).

## Обновление и удаление
Новая версия образа — тег `DDMMYYYY` в Docker Hub (авто-релиз по дате бинарника;
workflow скачивает оба архива: stable распаковывается в образ, beta кладётся zip-ом).
Uninstall-блок из генератора удаляет контейнер и настройки, данные сохраняет;
строка wipe дана комментарием и выполняется только вручную, удалит все включая данные.
