# Уведомления о стороннем ПО / Third-Party Notices

*(English version below — [English](#english))*

## Русский

IPList не встраивает в репозиторий сторонние файлы списков или исходный код. Приложение содержит URL-адреса и парсеры, которые позволяют пользователю скачивать совместимые публичные источники данных во время работы.

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

IPList does not vendor third-party list files or source code in this repository. The app contains URLs and parsers that let a user download compatible public data sources at runtime.

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
