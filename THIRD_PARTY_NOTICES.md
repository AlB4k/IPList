# Уведомления о стороннем ПО / Third-Party Notices

*(English version below — [English](#english))*

## Русский

IPList 1.4.0 встраивает лицензированный снимок каталога `pincetgore/amnezia-app-ru-list` и записанный снимок обогащения как резервные данные для чистой установки. Остальные сетевые списки загружаются во время работы и не вендорятся.

### pincetgore/amnezia-app-ru-list

Репозиторий: https://github.com/pincetgore/amnezia-app-ru-list

В приложение включены точные копии `config.yaml` и `LICENSE` из коммита `b8cb9566109232f07ceccfe98cce7388c84e773d` (дата коммита: 2026-09-17 19:56:50 +03:00). Снимок получен 2026-09-19 через `git fetch` этого коммита; `config.yaml` используется как резервный каталог при недоступности сети.

SHA-256 включённых файлов:

- `Resources/ThirdParty/pincetgore-config.yaml`: `d22b844be82ef80cbbb305adf5b9308245a97cfc6822c0c45a0d8897ea32b53e`
- `Resources/ThirdParty/pincetgore-LICENSE`: `89e30247532df2f24ffa96e846f8697222c413cbb1593e6a975fdf5e19955f66`
- `Resources/ThirdParty/enrichment-snapshot.json`: `b3f7af0481a6885e5e5353fb7e41ea957450d8835b50e48822f5995eed1dff2e`
- `Resources/ThirdParty/iplist-service-overrides.json`: verified project data maintained by IPList; AS61293 and 185.12.152.0/22 were checked against RIPEstat and DNS on 2026-09-22.

Лицензия: MIT. Текст лицензии включён в `Resources/ThirdParty/pincetgore-LICENSE`.

Локальный override `iplist-service-overrides.json` не является копией исходного репозитория: это небольшой набор корректировок проекта IPList для восполнения подтверждённых пробелов каталога (в частности, отдельная карточка 1С). Он распространяется вместе с проектом под лицензией IPList.

`enrichment-snapshot.json` получен 2026-09-19 22:14:59 +03:00 из включённого выше `config.yaml` (проверенный SHA-256 указан выше). Генератор `scripts/generate-enrichment-snapshot.swift` использовал системный DNS macOS через `DNSServiceGetAddrInfo` и официальный RIPEstat `announced-prefixes` (`https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS<asn>`). Запрошенное время наблюдения RIPEstat: `2026-09-19T19:14:59Z`; каждый запрос задаёт одночасовое окно, а принимаются только префиксы с timeline, покрывающим возвращённый `query_endtime`. Пределы: 8 параллельных запросов, 12 секунд на запрос, 60 секунд на весь запуск, 4 МиБ на ответ RIPEstat и 100000 префиксов RIPEstat. Снимок содержит 275 сервисов: DNS-доказательства есть у 274, префиксы ASN — у 88; 12 неполных записей явно помечены `stale`. В снимок не добавлялись выдуманные адреса; при сопоставлении его доказательства пересекаются с текущими маршрутами источника, а остальная часть остаётся неназначенной.

### lib4u/amnezia-tunneling-ru

Репозиторий: https://github.com/lib4u/amnezia-tunneling-ru

IPList использует этот репозиторий как источник по умолчанию для Amnezia-совместимых JSON-списков во время работы:

- `amnezia.json`
- `amnezia-ip-lite.json`
- `amnezia-ip.json`

Файлы и скрипты из `lib4u/amnezia-tunneling-ru` в этот репозиторий не коммитятся и не помещаются в `IPList.app`.

На момент подготовки проекта к публикации в апстрим-репозитории не было файла `LICENSE` в списке файлов на GitHub. Поэтому не копируйте, не вендорите, не зеркалируйте и не распространяйте сгенерированные им файлы списков внутри этого репозитория или в бинарных релизах, пока лицензия апстрима или разрешение мейнтейнера не будут прояснены.

### v2fly/domain-list-community

Репозиторий: https://github.com/v2fly/domain-list-community

IPList сохраняет URL этого MIT-лицензированного проекта для диагностики и совместимости с прежними настройками источников. Его файлы не включаются в репозиторий или приложение; действующий каталог 1.4.0 получает метаданные из `pincetgore/amnezia-app-ru-list`.

### AmneziaVPN и AmneziaWG

Сайт: https://amnezia.org/

IPList экспортирует JSON, предназначенный для импорта в настройки раздельного туннелирования AmneziaVPN, а также редактирует пользовательские `.conf` как данные AmneziaWG. IPList не включает код AmneziaVPN, AmneziaWG или WireGuard, не читает и не экспортирует `.vpn`, и не аффилирован с этими проектами.

---

## English

IPList 1.4.0 vendors a licensed `pincetgore/amnezia-app-ru-list` catalog snapshot and a recorded enrichment snapshot as clean-install fallback data. Other network lists are downloaded at runtime and are not vendored.

### pincetgore/amnezia-app-ru-list

Repository: https://github.com/pincetgore/amnezia-app-ru-list

The app includes exact copies of `config.yaml` and `LICENSE` from commit `b8cb9566109232f07ceccfe98cce7388c84e773d` (commit date: 2026-09-17 19:56:50 +03:00). The snapshot was obtained on 2026-09-19 by fetching that commit with Git; `config.yaml` is used as the bundled catalog fallback when the network is unavailable.

SHA-256 checksums of the bundled files:

- `Resources/ThirdParty/pincetgore-config.yaml`: `d22b844be82ef80cbbb305adf5b9308245a97cfc6822c0c45a0d8897ea32b53e`
- `Resources/ThirdParty/pincetgore-LICENSE`: `89e30247532df2f24ffa96e846f8697222c413cbb1593e6a975fdf5e19955f66`
- `Resources/ThirdParty/enrichment-snapshot.json`: `b3f7af0481a6885e5e5353fb7e41ea957450d8835b50e48822f5995eed1dff2e`

License: MIT. The license text is included in `Resources/ThirdParty/pincetgore-LICENSE`.

`enrichment-snapshot.json` was generated on 2026-09-19 22:14:59 +03:00 from the bundled `config.yaml` above (whose SHA-256 is verified above). `scripts/generate-enrichment-snapshot.swift` used macOS system DNS through `DNSServiceGetAddrInfo` and the official RIPEstat announced-prefixes endpoint (`https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS<asn>`). Its requested RIPEstat observation time was `2026-09-19T19:14:59Z`; each request fixes a one-hour observation window and accepts only prefixes whose timeline covers the returned `query_endtime`. Limits are 8 concurrent requests, 12 seconds per request, 60 seconds overall, 4 MiB per RIPEstat response, and 100000 RIPEstat prefixes. The snapshot contains 275 services: 274 have DNS evidence and 88 have ASN prefixes; 12 incomplete entries are explicitly marked `stale`. No addresses were invented; matching intersects its evidence with current source routes and leaves the remainder unassigned.

### lib4u/amnezia-tunneling-ru

Repository: https://github.com/lib4u/amnezia-tunneling-ru

IPList uses this repository as the default runtime source for Amnezia-compatible JSON lists:

- `amnezia.json`
- `amnezia-ip-lite.json`
- `amnezia-ip.json`

No files or scripts from `lib4u/amnezia-tunneling-ru` are committed into this repository or placed in `IPList.app`.

At the time this project was prepared for publication, the upstream repository did not expose a `LICENSE` file in its GitHub file list. Because of that, do not copy, vendor, mirror, or redistribute its generated list files inside this repository or binary releases unless the upstream license or maintainer permission is clarified.

### v2fly/domain-list-community

Repository: https://github.com/v2fly/domain-list-community

IPList retains this MIT-licensed project's URL for source diagnostics and compatibility with prior source settings. Its files are not bundled in the repository or app; the active 1.4.0 catalog gets metadata from `pincetgore/amnezia-app-ru-list`.

### AmneziaVPN and AmneziaWG

Website: https://amnezia.org/

IPList exports JSON intended to be imported into AmneziaVPN split tunneling settings and treats user-supplied `.conf` as AmneziaWG configuration data. IPList does not bundle AmneziaVPN, AmneziaWG, or WireGuard code, does not read or export `.vpn`, and is not affiliated with those projects.
