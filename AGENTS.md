# AGENTS.md — MikroBILL full: контекст проекта для LLM

> **Читать первым в каждом новом чате.** Здесь: что за проект, где что лежит,
> как собирается/стартует, как выходят релизы, куда класть код и что ломать нельзя.
> Repo: https://github.com/efkot-dev/mikrobill-full · ветка `main` · Pages-конфигуратор: https://efkot-dev.github.io/mikrobill-full/

---

## 0. Источник истины и порядок чтения

Приоритет: **код > AGENTS.md > README.md**. README описывает идею и может отставать (см. §12).

Обязательно прочитать перед изменениями (raw, ветка `main`):

| Файл | Ссылка |
|---|---|
| `Dockerfile` | https://raw.githubusercontent.com/efkot-dev/mikrobill-full/refs/heads/main/Dockerfile |
| `entrypoint.sh` | https://raw.githubusercontent.com/efkot-dev/mikrobill-full/refs/heads/main/entrypoint.sh |
| `.github/workflows/auto-release.yml` | https://raw.githubusercontent.com/efkot-dev/mikrobill-full/refs/heads/main/.github/workflows/auto-release.yml |
| `.github/workflows/wp-bundle.yml` | https://raw.githubusercontent.com/efkot-dev/mikrobill-full/refs/heads/main/.github/workflows/wp-bundle.yml |
| модуль, который правишь | `.../main/modules/<NN>-*.sh` |

Карта файлов: `https://api.github.com/repos/efkot-dev/mikrobill-full/git/trees/main?recursive=1`
Нет сети → просить пользователя вставить содержимое, **не угадывать**.

---

## 1. TL;DR

**MikroBILL** (сторонний биллинг для MikroTik, сайт mikro-bill.com) упакован в **один Docker-образ**,
который крутится **внутри MikroTik RouterOS 7** (`/container`, не Docker Engine).
Этот репозиторий — не сам биллинг, а **обвязка**: образ + оркестратор старта + генератор RouterOS-скриптов + авто-релизы.

- Внутри образа: Ubuntu 24.04, MariaDB, Apache 2.4 + PHP 8.4 (Sury), .NET 6 ASP.NET Core runtime, WP-CLI 2.12.0, сам MikroBILL.
- Бинарник MikroBILL — проприетарный, тянется с `https://mikro-bill.com/downloads/{stable,beta}`; **в git его нет**.
- Единственная точка монтирования: **`/mikrobill-data`** (папка на диске роутера).
- Логика старта **модульная**: `entrypoint.sh` (оркестратор) + `modules/00..07` (шаги). Оркестратор лежит **на диске роутера** и правится без пересборки образа; модули лежат **в образе**.
- Опционально (`ENABLE_WP=1`) поднимается WordPress-визитка оператора **полностью оффлайн** из WP-бандла, вшитого в образ.
- Релизы: ежедневно GitHub Actions → Docker Hub `efkot/mikrobill-full:<DDMMYYYY>` + `latest`.
- Архитектура образа: **только `linux/amd64`** → нужен x86-роутер или CHR. ARM-железо не поддерживается.
- Тестов, линтера и CI-прогонов контейнера в репозитории **нет**. Проверка — только ручной запуск.

---

## 2. Карта репозитория

```
/
├── AGENTS.md                        # этот файл (в образ не попадает: .dockerignore *.md)
├── README.md                        # пользовательское описание (может отставать)
├── Dockerfile                       # сборка образа, 4.1 KB
├── entrypoint.sh                    # ОРКЕСТРАТОР: только загрузка модулей, 4.7 KB
├── modules/                         # ШАГИ СТАРТА, копируются в /opt/mikrobill-modules
│   ├── 00-common.sh                 #   пути, env-дефолты, is_mounted/bind_dir/sql_escape
│   ├── 01-system-shims.sh           #   поддельные systemctl/busctl/dbus-send (нет systemd)
│   ├── 02-bind-mounts.sh            #   bind-mount данных на /mikrobill-data
│   ├── 03-secrets.sh                #   пароли БД и админа → secrets/
│   ├── 04-mariadb.sh                #   init datadir, mysqld_safe, права, auto-repair
│   ├── 05-web.sh                    #   Apache + опциональный WordPress (18 KB, самый большой)
│   ├── 06-mikrobill-install.sh      #   silent install / repair ядра MikroBILL
│   └── 07-mikrobill-supervisor.sh   #   бесконечный супервизор dotnet MikroBILL.dll /SERVER
├── index.html                       # КОНФИГУРАТОР (GitHub Pages), 48 KB, vanilla JS, ru/en
├── wp-setup.sh                      # LEGACY WP-скрипт, в образ НЕ копируется (см. §12)
├── wp/mikrobill-guard.php           # mu-plugin: ограничения прав в WP-админке
├── .github/workflows/
│   ├── auto-release.yml             #   daily 03:00 UTC → образ + GitHub Release
│   └── wp-bundle.yml                #   weekly Пн 04:00 UTC → wp-bundle-<hash12> Release
├── .dockerignore                    # .git .github *.tar *.docx *.md .env
└── .gitignore                       # stable.zip *.tar .env logs/
```

Ветки: `main`, `add-beta`. Релизов/тегов: 25 (`v<DDMMYYYY>` и `wp-bundle-<hash12>`).

**Большие файлы** (`index.html`, `05-web.sh`, `wp-bundle.yml`, `wp-setup.sh`) — читать целиком, только если задача про них.

---

## 3. Как это работает на роутере

```
Пользователь → index.html (Pages, всё считается в браузере)
   ├─ setup.rsc / uninstall.rsc / check.rsc  (+ bootstrap.rsc через приватный Gist)
   ↓ /import на роутере
RouterOS 7:
   /interface/veth veth-mikrobill → bridge (или routed-режим)
   /container/mounts  src=<disk>/mikrobill  dst=/mikrobill-data
   /container/envs    list=mikrobill (DB_*, MB_VERSION, ENABLE_WP, ...)
   /container/add     remote-image=registry-1.docker.io/efkot/mikrobill-full:latest
                      root-dir=<disk>/mikrobill/container
                      entrypoint=/bin/bash  cmd=/mikrobill-data/entrypoint.sh   ← ВАЖНО
   /ip/firewall/nat   dst-address=<белый IP> dst-port=80,443,3306,7402 → IP контейнера
   ↓
Контейнер: bash /mikrobill-data/entrypoint.sh (копия с RAW GitHub, скачана при установке)
   → modules из /opt/mikrobill-modules (из образа)
   → MariaDB + Apache + dotnet MikroBILL.dll /SERVER (супервизор = PID 1)
```

**Следствие:** `ENTRYPOINT ["/entrypoint.sh"]` в образе на роутере **не используется** — RouterOS переопределяет его.
Встроенная копия нужна для обычного `docker run` и как fallback; её блок 01 передаёт управление внешней копии на диске.

---

## 4. Точка входа и модули

### `entrypoint.sh` — что он делает (и только это)
1. Если есть `/mikrobill-data/entrypoint.sh` и `MB_ENTRYPOINT_EXTERNAL != 1` → `export MB_ENTRYPOINT_EXTERNAL=1; exec bash` туда (защита от рекурсии).
2. `set -u` — **`set -e` сознательно НЕ используется**, ошибки обрабатываются вручную.
3. Однократно (`MB_LOG_SET`) включает лог: `exec > >(tee -a /mikrobill-data/entrypoint.log) 2>&1`.
4. Ищет каталог модулей в порядке: `MB_MODULE_DIR` → `/mikrobill-data/modules` → `<dir скрипта>/modules` → `/opt/mikrobill-modules`. Нет → `FATAL`, `exit 1`.
5. `source 00-common.sh` (нет → `FATAL`).
6. Последовательно `source` модулей из **жёстко зашитого массива** `01…07`. Отсутствие любого → `FATAL exit 1`.
7. Если управление вернулось — `exit 1` (нормально никогда не происходит: 07 содержит вечный цикл).

### Модули

| Модуль | Делает | Ключевые пути / особенности |
|---|---|---|
| `00-common.sh` | дефолты путей и env, функции | `is_mounted()`, `bind_dir()`, `sql_escape()` (экранирует только `'`) |
| `01-system-shims.sh` | пишет `/usr/local/bin/systemctl` и копирует в `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`; заглушки `busctl`, `dbus-send` | `apache/httpd` → `apachectl`; `mikrobill` → флаги в `/var/run`; прочее → `exit 0`; `status` → 0/3 |
| `02-bind-mounts.sh` | снимает старое монтирование `/var/MikroBILL`, убивает симлинки, делает **bind-mount** | `mysql→/var/lib/mysql`, `web→/var/www/html`, `data→/var/MikroBILL` |
| `03-secrets.sh` | пароли: env → файл, иначе генерация один раз | `openssl rand -hex 16` (БД) / `12` (админ), `chmod 600`; миграция из `data/secrets` |
| `04-mariadb.sh` | `bind-address=0.0.0.0`, `skip-log-bin`, `skip-name-resolve`; init datadir; `mysqld_safe &`; wait ≤60 c; SQL-права; `mysqlcheck --auto-repair` | БД `utf8mb4_unicode_ci`; юзер на `%`, `localhost`, `127.0.0.1`; `REVOKE FILE` |
| `05-web.sh` | `apachectl start`; при `ENABLE_WP!=1` — `return 0`; иначе весь WordPress оффлайн | см. §7 WP; **никогда не роняет контейнер** — все ошибки мягкие |
| `06-mikrobill-install.sh` | детект установки, подготовка stable/beta, `dotnet MikroBILL.dll /SILENT_INSTALL=<json>`, web-файлы, права | JSON: `web_path`, `web_url`, `db_ip=127.0.0.1`, `db_port=3306`, `language=ru`, `lic_accept=1` |
| `07-mikrobill-supervisor.sh` | `trap TERM/INT`; вечный цикл: старт `dotnet /var/MikroBILL/bin/MikroBILL.dll /SERVER &`, `wait`, разбор флагов, рестарт через 5 с | пишет `$PIDFILE`; флаги stop/start/restart/container-stop |

**Правила шелла здесь (критично):**
- Модули **`source`-ятся**, не запускаются. `exit` в модуле = смерть всего entrypoint. Мягкий выход — `return 0 2>/dev/null || exit 0` (паттерн из `05`).
- Из-за `set -u` любое обращение к unset-переменной убивает старт → **всегда `${VAR:-}`**.
- Каждый модуль самодостаточен и идемпотентен; повторный старт не должен затирать данные.
- Комментарии и структура «Блоки 01…NN» — принятый стиль, сохранять.

---

## 5. Данные: диск ↔ контейнер

```
<disk>/mikrobill/            →  /mikrobill-data          (единственный mount)
├── entrypoint.sh            оркестратор, качается с RAW main при установке
├── entrypoint.log           лог старта (tee)
├── secrets/                 db_password, admin_password, wp_db_password, wp_admin_password (600)
├── mysql/                   →  /var/lib/mysql           (bind)
├── data/                    →  /var/MikroBILL           (bind, целиком!)
│   ├── MikroBILL.xml        конфиг ядра (Linux-версия игнорирует /confdir=)
│   ├── bin/MikroBILL.dll    ядро + bin/web
│   ├── mb_channel           установленный канал: stable|beta
│   └── cert/                сертификаты
├── web/                     →  /var/www/html            (bind)
│   ├── web.ver              маркер «web-файлы уже скопированы»
│   ├── payin/ actionin/ news/ tvin/   (chmod a=rwx — так требует установщик)
│   └── wp/                  WordPress: код + .wp_bundle_hash
├── container/               root-dir (rootfs образа), создаёт RouterOS
└── modules/                 опционально: перекрывают модули из образа
```

В образе (не на диске): `/opt/mikrobill-installer` (распакованный stable), `/opt/mikrobill-beta.zip`,
`/opt/wp-installers` (+ `manifest.json`, `BUNDLE_HASH`), `/opt/mikrobill-modules`, `/usr/local/bin/wp`, `/usr/share/dotnet`.

Порты (`EXPOSE`): **80** web+ACME · **443** https · **7402** ядро/MikroREMOTE · **3306** MariaDB.
Порт 80 на роутере должен быть свободен от `www`: `/ip/service/set www disabled=yes`.

---

## 6. Маркеры состояния (что делает старт идемпотентным)

| Маркер | Если есть | Если нет |
|---|---|---|
| `/mikrobill-data/entrypoint.sh` | встроенный entrypoint делает `exec` в него | работает встроенный |
| `MB_ENTRYPOINT_EXTERNAL=1` / `MB_LOG_SET=1` | не входить повторно / не включать tee дважды | — |
| `/var/lib/mysql/mysql` | datadir не инициализируется | `mariadb-install-db` |
| `secrets/db_password`, `secrets/admin_password` | пароль читается из файла | генерируется (env имеет приоритет и перезаписывает файл) |
| `/var/MikroBILL/bin/MikroBILL.dll` | установка не нужна | `NEED_INSTALL=1` |
| `/var/MikroBILL/MikroBILL.xml` | установка не нужна | **`NEED_INSTALL=1` — удаление = переустановка** |
| `/var/MikroBILL/mb_channel` | канал зафиксирован; `MB_VERSION` влияет **только на свежую установку** | пишется после успешного install |
| `$WEB_DIR/web.ver` | web из `bin/web` не копируется | `cp -rT /var/MikroBILL/bin/web → $WEB_DIR` |
| `$WP_DIR/wp-config.php` | WP установлен → только upgrade/поддержка | offline first install |
| `$WP_DATA/.wp_bundle_hash` vs `/opt/wp-installers/BUNDLE_HASH` | равны → апгрейда нет | различны → `wp_upgrade` |
| `/var/run/mikrobill.{start,stop,restart,container-stop}`, `.pid` | управление супервизором через systemctl-shim | — |

---

## 7. Переменные окружения (полный список из кода)

### Основные

| Переменная | Default | Где читается |
|---|---|---|
| `MB_VERSION` | `stable` (`stable`/`beta`) | `00`, `06` — только при свежей установке |
| `DB_NAME` / `DB_USER` | `mikrobill` / `mikrobill` | `00`, `04`, `06` |
| `DB_PASSWORD` | пусто → генерация | `03` → файл → `04`, `06` |
| `ADMIN_LOGIN` | `Admin` | `00`, `06` |
| `ADMIN_PASSWORD` | пусто → генерация | `03` → `06` |
| `CONTAINER_IP` | авто из `eth0` / `hostname -i` | `06`; `05` как fallback |
| `WEB_URL` | `http://$CONTAINER_IP` | `06` (вычисляется **внутри** install-ветки), `05` |

### Пути (переопределяемые, `00-common.sh`)
`WEB_DIR=/var/www/html` · `SECRET_DIR=/mikrobill-data/secrets` · `INSTALL_DIR=/opt/mikrobill-installer` ·
`DATA_DIR=/mikrobill-data/data` · `MYSQL_DIR=/mikrobill-data/mysql` · `WEB_DATA_DIR=/mikrobill-data/web`

### WordPress (`05-web.sh`, всё под `ENABLE_WP=1`)

| Переменная | Default |
|---|---|
| `ENABLE_WP` | `0` — выключено; `1` включает |
| `WP_INSTALLERS` | `/opt/wp-installers`, fallback `/mikrobill-data/wp-installers` |
| `WP_DATA` / `WP_DIR` | `/mikrobill-data/web/wp` / `/var/www/html/wp` |
| `WP_DB_NAME` / `WP_DB_USER` | `${DB_NAME}_wp` / `${DB_USER}_wp` |
| `WP_DB_PASS` / `WP_ADMIN_PASS` | пусто → генерация в `secrets/wp_*_password` |
| `WP_ADMIN_USER` / `WP_ADMIN_EMAIL` / `WP_TITLE` | `wpadmin` / `admin@localhost` / `MikroBILL Site` |
| `WP_DOMAIN` / `WP_ALIAS` | пусто → WP живёт в подкаталоге `/wp`; задан → отдельный vhost `mikrobill-wp.conf` |
| `WP_SCHEME` / `WP_BASE_URL` | из `WEB_URL`; base = `scheme://WP_DOMAIN` или `WEB_URL/wp` |

Состав бандла: `wordpress-ru_RU.zip` (с language pack), тема `kadence`, плагины `kadence-blocks`,
`fluentform`, `fluent-smtp`, `limit-login-attempts-reloaded`, `updraftplus`, mu-plugin `mikrobill-guard.php`.
Страницы: `home`, `tariffs`, `contacts`, `privacy`. Префикс таблиц `mbwp_<hex3>_`, `FS_METHOD=direct`,
автообновления и `DISALLOW_FILE_EDIT` выключены. `wp-config.php` — `chmod 640`.

### Служебные
`MB_MODULE_DIR` · `MB_ENTRYPOINT_EXTERNAL` · `MB_LOG_SET` · `RESTART_FLAG` · `STOP_FLAG` · `START_FLAG` · `CONTAINER_STOP_FLAG` · `PIDFILE`

### Генерируются конфигуратором, но **кодом не читаются** (см. §12)
`WP_LK_PREFIX`, `MB_DOMAIN`, `CONTAINER_MASK` (последняя — только в legacy `wp-setup.sh`).
Только legacy: `WP_ADMIN_NETWORKS`, `WP_ACME`.

---

## 8. CI/CD и релизы

### `auto-release.yml` — «Auto Release MikroBILL»
- Триггеры: `schedule: 0 3 * * *` (ежедневно 03:00 UTC) + `workflow_dispatch` с boolean `force`.
- Job `check-version`: качает `stable.zip` и `beta.zip` с mikro-bill.com; находит последний релиз `wp-bundle-*` (**нет → hard fail**, надо сначала запустить WP Bundle) и тянет у него только `manifest.json` → `bundle_hash` (валидация `^[0-9a-f]{12}$`).
- **Версия** = дата модификации `MikroBILL.dll|.exe` внутри `stable.zip` в формате **`DDMMYYYY`**; если бинарник не найден → `sha-<8 hex>`.
- Решение о сборке: `force` → да; тега нет на Docker Hub (`hub.docker.com/v2/repositories/<user>/mikrobill-full/tags/<version>`) → да; иначе — да, только если в body последнего релиза `v*` другой `wp-bundle-<hash12>`.
- Артефакты между job: `stable-zip`, `beta-zip`, `wp-bundle-zip` (+ `sha256sum -c`).
- Job `build-and-push`: buildx, `platforms: linux/amd64`, push в Docker Hub `<DOCKERHUB_USERNAME>/mikrobill-full:<version>` и `:latest`; GitHub Release `v<version>` с телом, содержащим `**Tag:**`, `**SHA256:**`, `**WP bundle:**` и вложением `stable.zip`.
- Secrets: `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`.

> Строка `**WP bundle:** \`wp-bundle-<hash>\`` в body релиза — **функциональный маркер**, по ней сравниваются бандлы. Формат ломать нельзя.

### `wp-bundle.yml` — «WP Bundle»
- Триггеры: `0 4 * * 1` (Пн 04:00 UTC) + `workflow_dispatch` `force`; `concurrency: wp-bundle`.
- Job `check-bundle`: версии core (`locale=ru_RU`) и 6 компонентов через API wordpress.org **без скачивания**; санити-regex версий.
- `bundle_hash` = sha256 от канонической строки: `schema=1`, `core`, `core_locale=ru_RU`, `kadence`, `kadence-blocks`, `fluentform`, `fluent-smtp`, `limit-login-attempts-reloaded`, `updraftplus`, **`guard=<sha256 wp/mikrobill-guard.php>`** → короткий 12-hex → тег `wp-bundle-<hash12>`.
- Если релиз с тегом уже содержит `wp-bundle.zip` — сборка пропускается (кроме `force`).
- Job `build-bundle`: кэш `downloads` по hash, скачивание пинованных версий, проверка версии core внутри архива и наличия `ru_RU.mo` и главных файлов плагинов, сборка `staging/` + `manifest.json` (schema 1, sha256 каждого файла), `zip -X`, `wp-bundle.zip.sha256`, публикация релиза (`--clobber` при force).

### Порядок и следствия
`wp-bundle` (Пн 04:00) → ближайший `auto-release` (03:00) подхватывает новый hash → пересборка образа → у пользователя при рестарте `05-web.sh` видит другой `BUNDLE_HASH` → оффлайн-апгрейд WP.
**Правка `wp/mikrobill-guard.php` меняет bundle_hash** и через сутки приводит к пересборке образа и апгрейду WP у всех.

### Локальная сборка
`docker build .` **упадёт без файлов контекста**: нужны `stable.zip`, `beta.zip`, `wp-bundle.zip` в корне
(их даёт CI; в git их нет). `.gitignore` содержит только `stable.zip` — `beta.zip`/`wp-bundle.zip` не игнорируются, случайно не коммитить.
Внутри контейнера используется `mount --bind`, поэтому локальный запуск требует права на монтирование (`--cap-add SYS_ADMIN` / `--privileged`); автотестов нет.

---

## 9. `index.html` — контракт с роутером

Один файл, vanilla JS, ru/en (`I18N`), всё считается локально. Публикуется с `main` через GitHub Pages.

Константы: `DOCKER_IMAGE='registry-1.docker.io/efkot/mikrobill-full:latest'`,
`ENTRYPOINT_URL='https://raw.githubusercontent.com/<user>/<repo>/main/entrypoint.sh'` (user/repo выводится из hostname Pages).

Поля → дефолты: `storage` (обязательный select: disk1/usb1/usb1-part1/usb2/sd1/nvme1/sata1/custom),
`folder=mikrobill`, `cname=mikrobill`, `usebridge=✓`, `bridge=bridge`, `ip=192.168.88.10`, `mask=24`,
`gw=192.168.88.1`, `nat=✓`, `whiteip=∅`, `boot=✓`, `mver=stable`, `dbpass/adminpass=∅`,
WP: `wpen`, `wpdomain`, `wplkprefix=lk|cabinet|kab|ab|custom`.

Функции: `cfg()`, `validate()`, `updateUi()`, `render()`, `buildSetup()`, `buildUninst()`, `buildDiag()`,
`buildBootstrap()`, `publishGist()`, `deleteGist()`, `copyText()`, `download()`, `crlf()`, `rsc()`.
**Экспорт всегда CRLF** — RouterOS читает файлы как Windows-текст. Скрипты только ASCII (без кириллицы), результат в `:log`.

`setup.rsc` делает: preflight (часы ≥2024, DNS, пакет container, диск, свободное место ≥1 GB / ≥2 GB с WP, bridge) →
создание папки → write-probe → `/tool/fetch` свежего `entrypoint.sh` → veth (+bridge port или routed-режим с masquerade) →
`/container/mounts` (`<name>-data`, dst `/mikrobill-data`) → envs → `/container/add ... shm-size=256.0MiB logging=yes entrypoint=/bin/bash cmd=/mikrobill-data/entrypoint.sh` → start → один dstnat-rule на белый IP (80,443,3306,7402) с comment `mb-<name>-nat`.

Env, которые реально пишет генератор: `DB_NAME=mikrobill`, `DB_USER=mikrobill`, `MB_VERSION`,
опционально `DB_PASSWORD`, `ADMIN_PASSWORD`; при WP — `ENABLE_WP=1`, `CONTAINER_IP`, `CONTAINER_MASK`,
`WP_DOMAIN=www.<домен>`, `WP_LK_PREFIX`, `MB_DOMAIN=<префикс>.<домен>`.

`uninstall.rsc`: stop → delay 10s → remove контейнера, envs, mounts, **своих** NAT по comment `mb-<name>`, address/bridge port/veth, папки `container`. **Данные сохраняет**; wipe — закомментированная строка, только вручную.
`check.rsc`: только чтение + `/disk/test direction=read` (никогда `write`).
Gist: приватный gist от bot-аккаунта, токен **обфусцирован в клиенте** (XOR), файлы `setup/uninstall/check` + `bootstrap.rsc`; bootstrap регистрирует `mikrobill-setup` / `mikrobill-uninstall` / `mikrobill-check` в System → Scripts; кнопка удаления gist.

---

## 10. Куда класть новое + рецепты

| Задача | Куда |
|---|---|
| шаг старта контейнера | новый `modules/NN-*.sh` + правка массива `MODULES` в `entrypoint.sh` (см. предупреждение ниже) |
| общие пути/функции | `modules/00-common.sh` |
| логика БД / гранты | `modules/04-mariadb.sh` |
| Apache / WordPress | `modules/05-web.sh` (**не** `wp-setup.sh`) |
| установка/каналы MikroBILL | `modules/06-mikrobill-install.sh` |
| поведение процесса, сигналы | `modules/07-mikrobill-supervisor.sh` + shim в `01` |
| пакеты, версии PHP/.NET/WP-CLI | `Dockerfile` |
| состав WP-бандла | `.github/workflows/wp-bundle.yml` (+ `05-web.sh` синхронно) |
| поля формы / RouterOS-скрипты | `index.html` (`cfg`, `validate`, `buildSetup`, `I18N` **ru и en**) |
| права в WP-админке | `wp/mikrobill-guard.php` |

**⚠ Добавление/переименование модуля — ломающая операция.** Список модулей зашит в `entrypoint.sh`,
который лежит **на диске у уже установленных роутеров** и обновляется только при новой установке.
Новый модуль старые роутеры не запустят; новый диск-оркестратор со старым образом даст `FATAL: module not found` и контейнер умрёт.
Любое изменение списка/имён модулей требует явного решения о совместимости.

**Рецепты**

*Новая env-переменная:* дефолт в `00-common.sh` (или `${VAR:-}` у потребителя) → использование в модуле →
поле + `buildSetup` + `I18N`(ru/en) в `index.html`, если задаётся пользователем → таблица §7 → README при необходимости.
Проверка: чистый первый старт **и** рестарт с существующими данными.

*Правка `entrypoint.sh`:* сохранить `set -u`, оба guard-флага, порядок поиска модулей, `source`-семантику и финальный `exit 1`;
помнить, что файл приедет на роутер с RAW `main` **без пересборки образа** → должен работать со старыми модулями.

*Правка `05-web.sh`:* ошибки WP не должны ронять контейнер (`return 0 2>/dev/null || exit 0`);
сохранять маркер `.wp_bundle_hash` и оффлайн-принцип (никаких скачиваний в рантайме).

*Смена версии компонента WP:* только через `wp-bundle.yml`; hash изменится сам; ручные теги не создавать.

*Правка `index.html`:* обновить ru **и** en, сохранить CRLF и ASCII в `.rsc`, не сломать `mb-<name>`-тегирование NAT (по нему работает uninstall).

---

## 11. Правила для LLM

**MUST**
1. Прочитать §0-файлы и целевой модуль **до** предложений; сказать, что прочитано.
2. Ссылаться только на реальные пути/функции из кода.
3. Минимальные диффы; сохранять стиль «Блоки 01…NN», русские комментарии, `set -u`, `${VAR:-}`.
4. Сохранять идемпотентность (§6) и мягкое поведение WP-модуля.
5. Помнить: `entrypoint.sh` — с диска (RAW main), модули — из образа; версионный перекос (§10).
6. При изменении env/портов/путей/состава бандла — обновить §5/§7/§8 и этот файл.
7. Не хватает данных → до 3 конкретных вопросов, не додумывать.
8. К каждому изменению — способ проверки (§13), включая сценарий «первый старт» и «рестарт».
9. Не писать код миграции и обратной совместимости со старых релизов (§16). Обновление — repull образа + повторный setup.rsc.

**MUST NOT**
1. Не менять схему тегов, формат `**WP bundle:**`, имена образов и `bundle_hash`-строку без явного запроса.
2. Не редактировать `wp-setup.sh` как «актуальный» код и не возвращать его в `Dockerfile`.
3. Не добавлять сетевые скачивания в рантайм WP (принцип — оффлайн из образа).
4. Не трогать `MikroBILL.xml`, `bin/`, `mysql/` и `secrets/` в коде деструктивно; не предлагать `rm` данных.
5. Не хардкодить пароли/токены, не логировать секреты, не «расшифровывать» gist-токен в ответах.
6. Не открывать 3306 наружу и не ослаблять гранты/`REVOKE FILE`.
7. Не менять порядок модулей и не переносить `WEB_URL`/IP-логику «по-тихому» (§12.3).
8. Не считать README истиной при расхождении с кодом.

---

## 12. Известные расхождения и грабли (проверено по коду)

1. **`WP_LK_PREFIX` и `MB_DOMAIN`** генерируются `index.html`, но **нигде не читаются** (`modules/`, `Dockerfile`). Поддомен ЛК и SAN-сертификат из подсказки конфигуратора фактически не настраиваются обвязкой. `CONTAINER_MASK` читается только legacy-скриптом.
2. **`wp-setup.sh` — legacy.** В `Dockerfile` его `COPY` закомментирован; `05-web.sh` прямо заявляет самодостаточность. Расхождения с новым модулем: `/var/www/site` (симлинк) vs `/var/www/html/wp`; `/mikrobill-data/wp` vs `/mikrobill-data/web/wp`; БД `wordpress`/`wpuser`/`operator` vs `mikrobill_wp`/`mikrobill_wp`/`wpadmin`; маркер `.mb-bundle-hash` vs `.wp_bundle_hash`; режимы PORT:8080/NAME + ACME vs простой vhost. Он ссылается на `/root/.acme.sh/acme.sh` и `/opt/wp-setup.sh`, которых в образе нет.
3. **Порядок модулей:** `05-web.sh` (WordPress) выполняется **до** `06-mikrobill-install.sh`, а `WEB_URL` вычисляется в `06` только внутри ветки установки. Поэтому на первом старте base URL WP может получиться из `CONTAINER_IP` или `http://127.0.0.1/wp`. Не «исправлять» перестановкой без запроса — сначала обсудить.
4. **acme.sh:** README говорит «внутри образа acme.sh», но `Dockerfile` его **не устанавливает**. Есть только `/var/www/letsencrypt/.well-known/acme-challenge` и `/var/MikroBILL/cert`. Сертификатами занимается ядро MikroBILL; `cron` в образе стоит, но модулями не запускается.
5. **README неполон:** не описаны `ENABLE_WP` и все `WP_*`, модульная структура, маркеры. Актуальный справочник по env — §7.
6. **`MB_VERSION` — только для свежей установки.** Переключение stable↔beta на живых данных ничего не меняет (лишь `NOTE` в логе); канал хранится в `/var/MikroBILL/mb_channel`.
7. **Удаление `MikroBILL.xml` = триггер переустановки** (`NEED_INSTALL=1`), как и отсутствие `bin/MikroBILL.dll`.Repair-ветка для beta **удаляет `$INSTALL_DIR`** целиком.
8. **Два разных «источника» оркестратора:** образ и RAW `main`. Установленный роутер не получает обновлений `entrypoint.sh` сам.
9. **Версия = дата бинарника `DDMMYYYY`.** Две сборки в один день дают один тег; `force` перезаписывает тег и `latest`. Релиз `v<version>` не уникален по содержанию.
10. **`auto-release` зависит от `wp-bundle`:** без хотя бы одного релиза `wp-bundle-*` job падает с ошибкой — это ожидаемо, а не баг.
11. **`sql_escape` экранирует только одинарные кавычки**, имена БД вставляются без backticks в `04-mariadb.sh`. Валидации `DB_NAME`/`DB_USER` нет — не принимать пользовательский ввод как безопасный.
12. **Права/сеть по умолчанию щедрые:** NAT-правило публикует **3306**; `root@127.0.0.1` с пустым паролем; `payin/actionin/news/tvin` — `a=rwx`. Ослаблять дальше нельзя, ужесточение — только по запросу (может сломать установщик).
13. **Gist-токен лежит в клиенте** (`index.html`, XOR-обфускация) — считать его публичным; допустимый scope — только `gist`. Реальные токены в код не добавлять.
14. **Только amd64.** На ARM-роутерах образ не запустится; `check.rsc` печатает архитектуру именно поэтому.
15. **Нет тестов/линтера.** В `entrypoint.sh` есть `shellcheck`-директивы — ориентир на shellcheck, но CI его не гоняет.
16. SSL/SAN. Сертификат выпускает ядро MikroBILL: /root/.acme.sh, webroot /var/www/html, файлы /etc/apache2/cert/mikrobill.{crt,key,chain}, свой https.conf с Listen 443 и одним vhost (ServerName = домен ЛК). Обвязка acme не запускает и не продлевает. Строка вызова acme правится вручную в GUI ядра — только так добавляются SAN (www, apex, ЛК). WP подхватывает сертификат при рестарте контейнера; cron/watcher нет. HTTP-01 для www/apex приходит в WP-vhost → в нём обязателен Alias /.well-known/acme-challenge/ → /var/www/html/.well-known/acme-challenge/ и исключение этого пути из редиректа на https.

---

## 13. Отладка

На роутере:
```
/log print follow where topics~"container"
/container/print detail
/container/shell [find where name=mikrobill]
/system/script/run mikrobill-check
```
Внутри контейнера:
```
tail -n 200 /mikrobill-data/entrypoint.log     # весь старт по модулям
cat /var/MikroBILL/mb_channel                  # установленный канал
ls -l /var/MikroBILL /var/MikroBILL/bin        # ядро и конфиг на месте?
mysql -uroot -e "show databases;"
curl -I http://127.0.0.1/                      # Apache + web MikroBILL
systemctl status mikrobill                     # это shim: 0=жив, 3=не жив
cat /var/run/mikrobill.pid
cat /opt/wp-installers/BUNDLE_HASH; cat /mikrobill-data/web/wp/.wp_bundle_hash
```
Логи: старт — `/mikrobill-data/entrypoint.log`; WP — строки `[wp]` / `[wp][error]` в нём же; Apache — стандартные логи Debian; БД — `mysqld_safe --skip-syslog`.

Типовые причины падения старта: не смонтирован `/mikrobill-data` (WARNING, данные не переживут пересоздание) ·
нет каталога модулей или `00-common.sh` (`FATAL`) · нет `MikroBILL.dll` после install (`FATAL`) · unset-переменная при `set -u`.

# после ручной выдачи SAN в GUI ядра — рестарт контейнера, 05 подхватит сертификат
/container/stop [find where name=mikrobill]; :delay 10s; /container/start [find where name=mikrobill]
openssl x509 -in /etc/apache2/cert/mikrobill.crt -noout -ext subjectAltName
apachectl -S

---

## 14. Безопасность

Секреты — только в `/mikrobill-data/secrets/*` (600) и в env контейнера; в коде/логах/фикстурах их быть не должно.
Пароль из env **перезаписывает** файл при каждом старте — ротация делается через env, а не правкой файла.
Не открывать 3306 без filter-правила. Не менять `REVOKE FILE`. WP-админка ограничена mu-plugin'ом `mikrobill-guard.php`
(запрет update/install/delete/edit_files, роль administrator не выдаётся, `siteurl`/`home` защищены; **WP-CLI обходит guard** — так работает оффлайн-апгрейд).

---

## 15. Актуальность

Файл — часть кода. PR, меняющий структуру, env, модули, порты, пути, маркеры или CI, **обязан** обновить соответствующий раздел.
Составлено по `main` @ `cbbe313` (2026-11-27). Ветка `add-beta` — историческая, за истину не брать.

## 16. Политика совместимости: миграций нет (с 2026-11-28)
Репозиторий не публичный, пользователь один. Обновление = repull образа / повторный setup.rsc, а не миграция данных.
Код миграции со старых релизов не пишем: переносы каталогов/БД/маркеров, чтение legacy-форматов, автоконвертация конфигов — запрещены.
Ломающие изменения (пути, имена БД, список модулей, формат маркеров) допустимы без слоёв совместимости; в описании релиза указывать «требуется repull + повторный setup.rsc».
Существующие миграционные блоки — кандидаты на удаление, новые не добавлять: 03-secrets.sh блок 02 (миграция секретов из data/secrets), 02-bind-mounts.sh блок 02 (снятие старого монтирования /var/MikroBILL).
Контрольная точка «проверить позже» (перед публичным релизом / появлением внешних пользователей): (1) версионный перекос диск-оркестратор ↔ модули (§10); (2) нужна ли миграция путей/БД/маркеров; (3) автообновление entrypoint.sh на диске. До этого — не усложнять.
Правка §10: предупреждение о ломающих изменениях списка модулей остаётся, но режим реакции — repull, а не слой совместимости.
