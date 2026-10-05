# MikroBILL в одном Docker-контейнере для MikroTik RouterOS 7

Внутри образа: MariaDB, Apache 2.4 + PHP, .NET 6, acme.sh, MikroBILL.
Единственная точка монтирования `/mikrobill-data`, логика старта — внешний
`entrypoint.sh` на диске роутера (правится без пересборки образа).

## Конфигуратор и генератор скриптов
**https://efkot-dev.github.io/mikrobill-full/** — заполняет поля и отдаёт готовые
`setup.rsc` / uninstall-блок под ваш диск, IP, bridge и пароли.

## Установка
1. Сгенерируйте и скачайте `setup.rsc`.
2. Загрузите его в Files роутера (WinBox/FTP).
3. `/import file=setup.rsc`, логи: `/log print follow where topics~"container"`.

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
Новая версия образа — тег `DDMMYYYY` в Docker Hub (авто-релиз по дате бинарника).
Uninstall-блок из генератора удаляет контейнер и настройки, данные сохраняет;
строка wipe дана комментарием и выполняется только вручную.
