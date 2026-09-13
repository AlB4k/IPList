# Публикация / Publishing Checklist

*(English version below — [English](#english))*

## Русский

Чек-лист для публикации репозитория на GitHub.

### Уже сделано

- [x] Выбрана лицензия и добавлен `LICENSE` — Apache License 2.0, правообладатель AlB4k, 2026.
- [x] Набор иконок приложения (`Resources/AppIcon.icns`, `Resources/AppIcon.iconset/`) и подключение в `Info.plist` через `scripts/build-app.sh`.
- [x] Ассеты для оформления GitHub-репозитория в `Resources/GitHub/`: social preview (1280×640), favicon (`.ico` + PNG нескольких размеров), лого для README.
- [x] README переведён и продублирован на русском (основной раздел) и английском.
- [x] Bundle identifier заменён на `io.github.alb4k.iplist` (обратный DNS от GitHub-аккаунта AlB4k).
- [x] Скриншоты добавлены в README (`Resources/Screenshots/`), персональные IP-адреса на скриншоте «Мои IP» заменены на тестовые из RFC 5737.
- [x] Репозиторий опубликован на GitHub: https://github.com/AlB4k/IPList

### Осталось сделать перед публикацией

- [ ] Нотаризация сознательно не делается — решение принято, распространяется как ad-hoc подписанная сборка с предупреждением Gatekeeper (см. README).
- [ ] Решить, нужна ли нотаризация приложения для распространения за пределами этого Mac — сейчас сборка подписана только ad-hoc (`codesign --sign -`), без Apple Developer ID. На чистой системе Gatekeeper покажет предупреждение при первом запуске (см. README, раздел «Установка из DMG на чистом Mac»).
- [ ] Добавить скриншоты интерфейса, если репозиторий должен быть понятен со страницы GitHub без сборки приложения.
- [ ] Пересмотреть `THIRD_PARTY_NOTICES.md`: не добавлять сторонние данные в репозиторий, пока не прояснена лицензия апстрима.
- [ ] Собрать свежий билд: `./scripts/build-app.sh`.
- [ ] Прогнать тесты: `./scripts/test.sh`.
- [ ] По желанию, перед релизом — `IPLIST_LIVE_TEST=1 ./scripts/test.sh`.

### Не коммитить

- `dist/` (в том числе собранные `.dmg`)
- `.build/`
- `DerivedData/`
- Файлы из `~/Library/Application Support/IPList/`
- Скачанные upstream-файлы списков (JSON), пока не прояснены условия их распространения.
- Личные экспорты AmneziaVPN с приватными вручную добавленными IP-адресами.

### Первые шаги на GitHub

```sh
git add .
git commit -m "Initial IPList macOS app"
```

Локальный репозиторий уже использует ветку `main`. Создайте пустой репозиторий на GitHub, добавьте его как `origin` и запушьте только после проверки того, что реально попадает в коммит.

### CI

Workflow GitHub Actions запускается на `macos-latest`, выполняет автономный Swift-тест-харнесс и собирает бандл приложения. По умолчанию живые сетевые тесты не запускаются, поэтому CI должен быть стабилен даже при медленных upstream-источниках.

---

## English

Checklist for making this repository ready for a public GitHub release.

### Already done

- [x] License chosen and `LICENSE` added — Apache License 2.0, copyright AlB4k, 2026.
- [x] Full app icon set (`Resources/AppIcon.icns`, `Resources/AppIcon.iconset/`) wired into `Info.plist` via `scripts/build-app.sh`.
- [x] GitHub repository assets in `Resources/GitHub/`: social preview (1280×640), favicon (`.ico` plus PNGs at several sizes), README logo.
- [x] README translated and duplicated in Russian (primary section) and English.
- [x] Bundle identifier changed to `io.github.alb4k.iplist` (reverse-DNS of the AlB4k GitHub account).
- [x] Screenshots added to the README (`Resources/Screenshots/`); the personal IP addresses in the "My IP" screenshot were replaced with RFC 5737 test addresses.
- [x] Repository published on GitHub: https://github.com/AlB4k/IPList

### Still required before public release

- [ ] Notarization was deliberately skipped — the app ships as an ad-hoc signed build with a Gatekeeper warning on first launch (see README).
- [ ] Review `THIRD_PARTY_NOTICES.md` and keep third-party data out of the repository unless its license allows redistribution.
- [ ] Create a fresh build with `./scripts/build-app.sh`.
- [ ] Run `./scripts/test.sh`.
- [ ] Optionally run `IPLIST_LIVE_TEST=1 ./scripts/test.sh` before a tagged release.

### Do Not Commit

- `dist/` (including any built `.dmg`)
- `.build/`
- `DerivedData/`
- Files from `~/Library/Application Support/IPList/`
- Downloaded upstream JSON/list files unless their redistribution terms are clarified.
- Personal AmneziaVPN exports that contain private manual IP entries.

### Suggested First GitHub Steps

```sh
git add .
git commit -m "Initial IPList macOS app"
```

The local repository already uses the `main` branch. Then create an empty GitHub repository and add it as `origin`. Push only after reviewing the staged files.

### CI

The included GitHub Actions workflow runs on `macos-latest`, executes the standalone Swift test harness, and builds the app bundle. It does not run live network tests by default, so CI should be stable even when upstream list services are slow.
