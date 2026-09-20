<p align="center">
  <img src="Resources/GitHub/logo-256.png" alt="IPList logo" width="128" height="128">
</p>

<h1 align="center">IPList</h1>

<p align="center">
  <a href="#русский">Русский</a> · <a href="#english">English</a>
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue.svg"></a>
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-blue">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.9-orange">
</p>

---

## Русский

**IPList 1.4.0** — нативное приложение для macOS 13+, которое собирает и поддерживает список IPv4/CIDR для раздельного туннелирования AmneziaVPN и AmneziaWG. Оно показывает обновляемый каталог российских сервисов, помогает выбрать нужные маршруты и создаёт JSON для AmneziaVPN либо строку `AllowedIPs` и отдельные копии `.conf` для AmneziaWG.

### Каталог, источники и выбор

IPList получает адресные источники [lib4u/amnezia-tunneling-ru](https://github.com/lib4u/amnezia-tunneling-ru): `amnezia.json` (Targeted), `amnezia-ip-lite.json` (Lite) и `amnezia-ip.json` (Full). Метаданные каталога берутся из [pincetgore/amnezia-app-ru-list](https://github.com/pincetgore/amnezia-app-ru-list); в приложение включён проверенный снимок как резерв для чистой установки. DNS-записи запрашиваются через системный DNS macOS, ASN-префиксы — у RIPEstat. Подробнее о происхождении и лицензиях — в [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Каталог содержит категории, сервисы, домены, ASN, явные диапазоны и найденные адреса для текущего режима. Поиск находит сервис по названию, домену, ASN, IP или пересекающемуся CIDR; например, «Аэрофлот» находится по `Аэрофлот`, `aeroflot.ru`, AS34571 и сопоставленному адресу. Сервисы, которых нет в метаданных, остаются видимы как «Дополнительные ресурсы lib4u», а неприписанные части исходников — как выбранные по умолчанию «Остальные сети источника».

Отметки категорий и сервисов действуют одинаково в Targeted, Lite и Full. Отмеченный сервис добавляет свои маршруты текущего режима; снятая отметка их исключает. Общая часть сети остаётся, пока нужна хотя бы одному другому отмеченному сервису. «Остальные сети источника» имеют отдельную отметку, а «Мои IP» добавляются только при включённой настройке. На чистой установке выбраны все сервисы и остатки, поэтому Lite и Full повторяют полный исходный набор. Именные профили сохраняют этот выбор, режим и настройку «Мои IP».

«Проверить сейчас» и расписание получают каталог и все три источника как одну транзакцию. Новая модель публикуется только после проверки полноты: объединение сервисных маршрутов и «Остальных сетей источника» точно равно нормализованному источнику Lite/Full. Если источник, DNS или RIPEstat недоступны, предыдущие подтверждённые данные сохраняются с указанием возраста; неуспешная проверка не меняет последний успешный каталог, выбор или автоматический экспорт. В диагностике показаны результаты Targeted, Lite, Full, каталога, DNS и RIPEstat.

### Выгрузка

Обычный JSON остаётся совместимым с импортом AmneziaVPN. В AmneziaVPN выберите режим раздельного туннелирования «адреса из списка НЕ используют VPN», затем импортируйте файл. Повторный импорт зависит от версии клиента: проверьте, заменил ли он старые правила или объединил их.

Вкладка «Выгрузка» также формирует строку вида:

```ini
AllowedIPs = 1.1.1.1/32, 192.0.2.0/24
```

Одиночный IPv4 записывается как `/32`; CIDR нормализуются, семантически дедуплицируются и сортируются. `AllowedIPs` направляет перечисленные сети **через VPN к выбранному peer**. Для обычного обхода VPN используйте JSON-исключения AmneziaVPN либо действие «Пустить выбранное мимо VPN» при создании `.conf` ниже.

«Создать конфигурацию AmneziaWG» читает выбранные `.conf` только для создания новых файлов. Исходники не перезаписываются, ключи не сохраняются в состояние, историю или журналы, а обработка выполняется в памяти. Можно выбрать peer, если их несколько, и одну из операций:

- **Добавить к существующим** — объединяет выбранные маршруты с `AllowedIPs`.
- **Заменить выбранными** — оставляет выбранные IPv4; существующие IPv6 можно сохранить отдельной настройкой.
- **Пустить выбранное мимо VPN** — вычитает выбранные IPv4/CIDR из существующих `AllowedIPs`; это действие выбрано по умолчанию.

Перед записью IPList проверяет структуру, CIDR и новые пересечения между peer. Для нескольких входных файлов создаются независимые `-iplist.conf` в выбранной папке; одинаковые имена получают детерминированный суффикс. IPList не перезаписывает входной или существующий выходной файл.

Full содержит очень большой набор маршрутов. Перед копированием, сохранением или созданием конфигурации в режиме Full приложение выводит блокирующее предупреждение: Android/iOS могут не поднять туннель с таким объёмом. Для телефона обычно выбирайте Lite или отдельные сервисы. Проверка синтаксиса не гарантирует, что другой клиент или устройство установит тысячи маршрутов.

Файлы `.vpn` не поддерживаются: IPList не читает, не изменяет и не экспортирует их. Этот формат содержит профиль и секреты, а встроенное раздельное туннелирование AmneziaVPN хранится отдельно от серверного профиля.

### Хранение, обновление и приватность

Состояние хранится под текущим пользователем macOS:

```text
~/Library/Application Support/IPList/
```

- `state.json` — каталог, выбор, профили, ручные адреса, настройки, диагностические данные и кэш;
- `state-before-v1.4.json` — разовая резервная копия состояния 1.3.x перед первой миграцией 1.4.0;
- `state-before-v1.1.json` — резервная копия более ранней миграции, если она существовала;
- `amnezia-direct.json` — текущий автоматически сохранённый JSON-экспорт.

Ручные IP, группы, заметки, профили, расписание и история сохраняются при миграции. Не добавляйте эту папку, личные JSON-экспорты, `.conf`, `.vpn` или ключи в Git.

### Установка и разработка

Соберите локальное приложение:

```sh
./scripts/build-app.sh
open dist/IPList.app
```

Сборка подписана ad-hoc (`codesign --sign -`) и не нотаризована. На другом Mac Gatekeeper потребует явного подтверждения первого запуска; для публичного распространения требуется Developer ID и нотарификация.

Проверки разработчика:

```sh
./scripts/test.sh
swift build
swift build -c release
./scripts/build-app.sh
IPLIST_LIVE_TEST=1 ./scripts/test.sh
```

Живой тест обращается к текущим источникам и поэтому требует сети. Обычный набор не зависит от сети и проверяет CIDR-операции, обычный JSON, `AllowedIPs`, сохранность `.conf`, выбор во всех режимах, атомарное обновление и миграцию.

### Лицензия

Исходный код IPList распространяется по Apache License 2.0 — [LICENSE](LICENSE). Список сторонних компонентов, снимков и ограничений распространения — [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Источники адресов lib4u не вендорятся и не входят в бинарный релиз.

---

## English

**IPList 1.4.0** is a native macOS 13+ app that builds and maintains IPv4/CIDR lists for AmneziaVPN and AmneziaWG split tunneling. It presents an updatable Russian-service catalog, lets you select routes, and creates either AmneziaVPN JSON or an `AllowedIPs` line and separate AmneziaWG `.conf` outputs.

### Catalog, sources, and selection

IPList loads [lib4u/amnezia-tunneling-ru](https://github.com/lib4u/amnezia-tunneling-ru) address sources: `amnezia.json` (Targeted), `amnezia-ip-lite.json` (Lite), and `amnezia-ip.json` (Full). The service catalog comes from [pincetgore/amnezia-app-ru-list](https://github.com/pincetgore/amnezia-app-ru-list), with a verified bundled snapshot for a clean-install fallback. DNS uses macOS system DNS and ASN prefixes use RIPEstat. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for provenance and licenses.

The catalog includes categories, services, domains, ASN values, explicit ranges, and matched routes for the current mode. Search accepts service name, domain, ASN, IP, or intersecting CIDR; for example, Aeroflot is found by `Аэрофлот`, `aeroflot.ru`, AS34571, and a matched address. Entries absent from catalog metadata remain visible as “Additional lib4u resources”, while unmatched source fragments appear as the selected-by-default “Other source networks”.

Category and service choices have the same meaning in Targeted, Lite, and Full. Selecting a service includes its current-mode routes; clearing it excludes its own routes. A shared fragment stays while another selected service owns it. “Other source networks” have their own choice, and “My IP” entries are included only when enabled. A clean install selects every service and remainder, so Lite and Full reproduce their complete source lists. Named profiles retain the selection, mode, and “My IP” setting.

“Check now” and the schedule load the catalog and all three sources as one transaction. The candidate is published only after proving that service routes plus “Other source networks” exactly reconstruct the normalized Lite/Full source sets. A catalog, DNS, or RIPEstat failure keeps the previous verified data with an age marker; a failed check leaves the last successful catalog, selection, and automatic export unchanged. Diagnostics show Targeted, Lite, Full, catalog, DNS, and RIPEstat results.

### Export

The normal JSON export remains compatible with AmneziaVPN import. In AmneziaVPN choose the split-tunneling mode where addresses in the list do **not** use VPN, then import the JSON. Check how the installed client handles repeat imports: versions and workflows may replace or merge old rules.

The Export page also creates a line such as:

```ini
AllowedIPs = 1.1.1.1/32, 192.0.2.0/24
```

Individual IPv4 values become `/32`; CIDRs are normalized, semantically deduplicated, and sorted. `AllowedIPs` sends the listed networks **through VPN to the selected peer**. For a regular VPN bypass, use AmneziaVPN JSON exclusions or the “Send selected outside VPN” operation when creating a `.conf` below.

“Create AmneziaWG configuration” reads selected `.conf` files only to create new files. Inputs are never overwritten; keys are not stored in application state, history, or logs, and are handled in memory. Choose a peer when there are several and one operation:

- **Add to existing** merges selected routes into `AllowedIPs`.
- **Replace with selected** writes selected IPv4 routes; an option retains existing IPv6 routes.
- **Send selected outside VPN** subtracts selected IPv4/CIDRs from existing `AllowedIPs`; this is the default operation.

Before writing, IPList validates structure, CIDRs, and new peer-to-peer overlaps. Multiple input files produce independent `-iplist.conf` files in the selected folder; duplicate input names receive a deterministic suffix. IPList never overwrites an input or existing output.

Full can contain a very large route set. Before copying, saving, or creating a configuration in Full mode, the app presents a blocking warning: Android/iOS may fail to bring up a tunnel with that volume. Lite or selected services are usually better for phones. Syntax validation cannot guarantee that a different client or device will install thousands of routes.

`.vpn` files are out of scope. IPList does not read, modify, or export them: they contain a profile and secrets, while AmneziaVPN’s built-in split-tunneling settings are separate from the server profile.

### Storage, upgrade, and privacy

State lives under the current macOS user:

```text
~/Library/Application Support/IPList/
```

- `state.json` — catalog, selection, profiles, manual entries, settings, diagnostics, and cache;
- `state-before-v1.4.json` — one-time 1.3.x backup before the first 1.4.0 migration;
- `state-before-v1.1.json` — an earlier migration backup, when present;
- `amnezia-direct.json` — the current automatically saved JSON export.

Manual IPs, groups, notes, profiles, schedule, and history survive migration. Do not add this directory, personal JSON exports, `.conf`, `.vpn`, or keys to Git.

### Installation and development

Build the local app:

```sh
./scripts/build-app.sh
open dist/IPList.app
```

The bundle is ad-hoc signed (`codesign --sign -`) and not notarized. Gatekeeper requires an explicit first-launch confirmation on another Mac; public distribution requires a Developer ID signature and notarization.

Developer checks:

```sh
./scripts/test.sh
swift build
swift build -c release
./scripts/build-app.sh
IPLIST_LIVE_TEST=1 ./scripts/test.sh
```

The live test contacts current sources and needs network access. The regular suite is offline and covers CIDR operations, normal JSON, `AllowedIPs`, `.conf` preservation, selection in every mode, atomic refresh, and migration.

### License

IPList source code is Apache License 2.0 — [LICENSE](LICENSE). [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) records third-party components, snapshots, and redistribution constraints. lib4u address-source files are not vendored or included in binary releases.
