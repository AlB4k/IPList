# Публикация IPList 1.4.1 / IPList 1.4.1 publishing

*(English version below — [English](#english))*

## Русский

Этот список относится к hotfix-релизу **1.4.1 (build 8)**. Тег и GitHub Release создаются отдельно после успешной проверки артефакта.

### Подготовлено

- [x] Версия бандла — `1.4.1`, build `8`, bundle ID `io.github.alb4k.iplist`.
- [x] Локальный `dist/IPList.app` собирается из release-бинарника, получает иконку, лицензированный каталог и снимок обогащения, затем подписывается ad-hoc.
- [x] Документация описывает каталог, выбор во всех режимах, атомарное обновление, JSON/`AllowedIPs`, операции `.conf`, мобильное предупреждение Full, приватность ключей, резервную копию v1.4 и отказ от `.vpn`.
- [x] [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) фиксирует provenance и лицензии включённых ресурсов; адресные списки lib4u не включаются.
- [x] Скриншоты в `Resources/Screenshots/` используют тестовые RFC 5737 адреса для «Мои IP».

### Выполнить перед внешней публикацией

1. Запустить `./scripts/test.sh`, `swift build`, `swift build -c release`, `./scripts/build-app.sh`, `codesign --verify --deep --strict --verbose=2 dist/IPList.app` и `plutil -p dist/IPList.app/Contents/Info.plist`.
2. При доступной сети запустить `IPLIST_LIVE_TEST=1 ./scripts/test.sh` и записать дату, доступность источников и ограничения текущего набора.
3. Проверить содержимое `dist/IPList.app/Contents/Resources/ThirdParty/` по SHA-256 против [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
4. Провести GUI-приёмку в изолированном временном состоянии: поиск Аэрофлота, Targeted/Lite/Full, JSON, `AllowedIPs`, одиночный и пакетный `.conf`, ошибка валидации, предупреждение Full и сохранность состояния при неудачном обновлении.
5. Если установлены `awg`, `wg-quick` или AmneziaWG, проверить только обезличенный, неконнектируемый fixture `.conf`. Не импортировать реальные ключи и не подключать VPN. Недоступность такого клиента или инструмента указывается как блокер совместимости клиента.
6. Отметить в примечаниях к релизу, что сборка подписана ad-hoc и не нотарифицирована; пользователь может разрешить первый запуск через настройки macOS.
7. После успешной проверки создать тег `v1.4.1`, опубликовать DMG в GitHub Release и проверить контрольную сумму загруженного файла.

### Никогда не коммитить или не прикладывать к релизу

- `dist/`, `.build/`, `DerivedData/`, DMG и другие продукты сборки;
- `~/Library/Application Support/IPList/`, включая `state.json`, резервные копии и автоматический JSON;
- личные JSON-экспорты, `.conf`, `.vpn`, ключи, токены, credential/config exports;
- загруженные или сгенерированные адресные списки lib4u до явного разрешения их лицензии.

### Подпись и распространение

`scripts/build-app.sh` выполняет `codesign --sign -`. Это локальная ad-hoc подпись; нотаризация не выполняется. Пользователь другого Mac может увидеть Gatekeeper и должен явно разрешить первый запуск. Для бесшовной установки без этого шага нужны Apple Developer ID и нотарификация.

---

## English

This checklist applies to the **1.4.1 (build 8)** hotfix release. The tag and GitHub Release are created separately after the artifact passes verification.

### Prepared

- [x] Bundle version is `1.4.1`, build `8`, with bundle ID `io.github.alb4k.iplist`.
- [x] Local `dist/IPList.app` is built from the release binary, receives the icon, licensed catalog, and enrichment snapshot, then is ad-hoc signed.
- [x] Documentation covers the catalog, all-mode selection, atomic refresh, JSON/`AllowedIPs`, `.conf` operations, Full mobile warning, key privacy, v1.4 backup, and `.vpn` non-support.
- [x] [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) records provenance and licenses for bundled resources; lib4u address lists are excluded.
- [x] Screenshots in `Resources/Screenshots/` use RFC 5737 test addresses for “My IP”.

### Required before external publication

1. Run `./scripts/test.sh`, `swift build`, `swift build -c release`, `./scripts/build-app.sh`, `codesign --verify --deep --strict --verbose=2 dist/IPList.app`, and `plutil -p dist/IPList.app/Contents/Info.plist`.
2. With network access, run `IPLIST_LIVE_TEST=1 ./scripts/test.sh` and record the date, source availability, and current-list limitations.
3. Compare `dist/IPList.app/Contents/Resources/ThirdParty/` SHA-256 values with [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
4. Perform GUI acceptance in isolated temporary state: Aeroflot search, Targeted/Lite/Full, JSON, `AllowedIPs`, one-file and batch `.conf`, validation error, Full warning, and state preservation after a failed refresh.
5. If `awg`, `wg-quick`, or AmneziaWG is installed, validate only a sanitized, non-connectable fixture `.conf`. Do not import real keys or establish a VPN connection. Missing client tooling is a client-compatibility blocker.
6. State in the release notes that the build is ad-hoc signed and not notarized; the user may need to allow first launch in macOS settings.
7. After successful verification, create tag `v1.4.1`, publish the DMG in GitHub Release, and compare the uploaded asset checksum.

### Never commit or attach to a release

- `dist/`, `.build/`, `DerivedData/`, DMGs, or other build products;
- `~/Library/Application Support/IPList/`, including `state.json`, backups, and automatic JSON;
- personal JSON exports, `.conf`, `.vpn`, keys, tokens, and credential/config exports;
- downloaded or generated lib4u address lists until their redistribution license is explicitly cleared.

### Signing and distribution

`scripts/build-app.sh` runs `codesign --sign -`. This is local ad-hoc signing; no notarization is performed. A person using another Mac may see Gatekeeper and must explicitly allow the first launch. Seamless installation without this step requires Apple Developer ID signing and notarization.
