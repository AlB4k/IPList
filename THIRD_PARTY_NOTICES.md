# Уведомления о стороннем ПО / Third-Party Notices

*(English version below — [English](#english))*

## Русский

IPList встраивает лицензированный снимок каталога `pincetgore/amnezia-app-ru-list` как резервный источник. Остальные сетевые списки загружаются во время работы.

### pincetgore/amnezia-app-ru-list

Репозиторий: https://github.com/pincetgore/amnezia-app-ru-list

В приложение включены точные копии `config.yaml` и `LICENSE` из коммита `b8cb9566109232f07ceccfe98cce7388c84e773d` (дата коммита: 2026-09-17 19:56:50 +03:00). Снимок получен 2026-09-19 через `git fetch` этого коммита; `config.yaml` используется как резервный каталог при недоступности сети.

SHA-256 включённых файлов:

- `Resources/ThirdParty/pincetgore-config.yaml`: `d22b844be82ef80cbbb305adf5b9308245a97cfc6822c0c45a0d8897ea32b53e`
- `Resources/ThirdParty/pincetgore-LICENSE`: `89e30247532df2f24ffa96e846f8697222c413cbb1593e6a975fdf5e19955f66`

Лицензия: MIT. Текст лицензии включён в `Resources/ThirdParty/pincetgore-LICENSE`.

Снимок обогащения по сервисам (`enrichment-snapshot.json`) здесь не создаётся: его детерминированная генерация относится к Task 4 и требует сетевых DNS/RIPEstat данных с отдельной записью происхождения. Приложение использует каталог как резерв и не выдаёт отсутствующий снимок обогащения за готовые доказательства адресов.

### lib4u/amnezia-tunneling-ru

Репозиторий: https://github.com/lib4u/amnezia-tunneling-ru

IPList использует этот репозиторий как источник по умолчанию для Amnezia-совместимых JSON-списков во время работы:

- `amnezia.json`
- `amnezia-ip-lite.json`
- `amnezia-ip.json`

Файлы и скрипты из `lib4u/amnezia-tunneling-ru` в этот репозиторий не коммитятся.

На момент подготовки проекта к публикации в апстрим-репозитории не было файла `LICENSE` в списке файлов на GitHub. Поэтому не копируйте, не вендорите, не зеркалируйте и не распространяйте сгенерированные им файлы списков внутри этого репозитория или в бинарных релизах, пока лицензия апстрима или разрешение мейнтейнера не будут прояснены.

### v2fly/domain-list-community

Репозиторий: https://github.com/v2fly/domain-list-community

IPList использует этот репозиторий как источник по умолчанию для метаданных категорий/доменов. Согласно метаданным репозитория на GitHub, апстрим-проект опубликован под лицензией MIT.

Файлы из `v2fly/domain-list-community` в этот репозиторий не коммитятся.

### AmneziaVPN

Сайт: https://amnezia.org/

IPList экспортирует JSON, предназначенный для импорта в настройки раздельного туннелирования AmneziaVPN. IPList — независимый инструмент, не аффилированный с AmneziaVPN.

---

## English

IPList vendors a licensed snapshot of `pincetgore/amnezia-app-ru-list` as a bundled fallback. Other network lists are downloaded at runtime.

### pincetgore/amnezia-app-ru-list

Repository: https://github.com/pincetgore/amnezia-app-ru-list

The app includes exact copies of `config.yaml` and `LICENSE` from commit `b8cb9566109232f07ceccfe98cce7388c84e773d` (commit date: 2026-09-17 19:56:50 +03:00). The snapshot was obtained on 2026-09-19 by fetching that commit with Git; `config.yaml` is used as the bundled catalog fallback when the network is unavailable.

SHA-256 checksums of the bundled files:

- `Resources/ThirdParty/pincetgore-config.yaml`: `d22b844be82ef80cbbb305adf5b9308245a97cfc6822c0c45a0d8897ea32b53e`
- `Resources/ThirdParty/pincetgore-LICENSE`: `89e30247532df2f24ffa96e846f8697222c413cbb1593e6a975fdf5e19955f66`

License: MIT. The license text is included in `Resources/ThirdParty/pincetgore-LICENSE`.

No `enrichment-snapshot.json` is included here: deterministic per-service enrichment generation belongs to Task 4 and requires network DNS/RIPEstat data with separately recorded provenance. The app uses the catalog as a fallback and does not treat a missing enrichment snapshot as address evidence.

### lib4u/amnezia-tunneling-ru

Repository: https://github.com/lib4u/amnezia-tunneling-ru

IPList uses this repository as the default runtime source for Amnezia-compatible JSON lists:

- `amnezia.json`
- `amnezia-ip-lite.json`
- `amnezia-ip.json`

No files or scripts from `lib4u/amnezia-tunneling-ru` are committed into this repository.

At the time this project was prepared for publication, the upstream repository did not expose a `LICENSE` file in its GitHub file list. Because of that, do not copy, vendor, mirror, or redistribute its generated list files inside this repository or binary releases unless the upstream license or maintainer permission is clarified.

### v2fly/domain-list-community

Repository: https://github.com/v2fly/domain-list-community

IPList uses this repository as the default runtime source for category/domain metadata. The upstream project is published with an MIT license according to its GitHub repository metadata.

No files from `v2fly/domain-list-community` are committed into this repository.

### AmneziaVPN

Website: https://amnezia.org/

IPList exports JSON intended to be imported into AmneziaVPN split tunneling settings. IPList is an independent tool and is not affiliated with AmneziaVPN.
