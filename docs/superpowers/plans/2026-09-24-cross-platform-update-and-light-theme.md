# Проверка обновлений и светлая тема для macOS/Windows — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить в macOS- и Windows-приложения проверку новой версии из GitHub Releases и явную светлую тему с проверенной читаемостью в обеих независимых ветках.

**Architecture:** Общий контракт проверки релизов принимает URL API GitHub Releases и текущую версию, возвращает состояние `актуально / доступно обновление / ошибка`; macOS SwiftUI и Windows WPF реализуют его своими UI-адаптерами. Цвета каждой платформы переводятся на явную светлую палитру семантических ролей с контрастными текстами и фонами. Изменения выполняются раздельно: macOS в текущей ветке, Windows в `codex/windows-1.4.0`.

**Tech Stack:** macOS: Swift 5.9, SwiftUI/AppKit, Foundation `URLSession`; Windows: C# 13, .NET 10, WPF, `HttpClient`; обе платформы используют GitHub Releases API и отдельные тесты.

**Spec:** пользовательский запрос от 2026-09-24; текущая архитектура зафиксирована в `Package.swift`, `Sources/IPList/App.swift`, `scripts/build-app.sh`.

## Global Constraints

- Не менять текущую атомарность обновления источников IPList: проверка версии приложения не должна смешиваться с `Store.refresh()`.
- Не смешивать изменения macOS и Windows: Windows-файлы изменяются только в `codex/windows-1.4.0`.
- Каждый элемент «Мои IP» имеет собственный флаг включения в выгрузку; снятый флаг исключает только этот элемент, не удаляя его из сохранённых данных.
- Не полагаться на системную тёмную тему: интерфейс должен оставаться читаемым при явной светлой схеме.
- Не менять сетевые URL источников адресов; GitHub Release API — отдельный endpoint.
- Существующие незакоммиченные `.gui-fixture-state.json` и `.gui-input.conf` не трогать.

## Review Focus

- GitHub API вернул новый релиз, prerelease или неожиданный JSON — показать безопасное состояние и не считать приложение устаревшим без валидной версии; тест принадлежит задаче 1.
- Нет сети, timeout или HTTP 403/404 — UI показывает понятную ошибку и сохраняет рабочее состояние; тест принадлежит задаче 1.
- Текущая версия равна/новее опубликованной — не показывать ложное обновление; тест принадлежит задаче 1.
- Светлый фон, secondary/tertiary text, ссылки, ошибки, предупреждения, поля и disabled-кнопки — все роли имеют достаточный контраст; тест принадлежит задаче 2.
- Windows API/UI отсутствует в текущем checkout — отдельный Windows deliverable не должен маскироваться макросами; проверка принадлежит задаче 3.

---

### Task 1: Общий клиент проверки GitHub-релиза

**Files:**
- Create: `Sources/IPList/AppUpdateChecker.swift`
- Modify: `Tests/CoreChecks.swift` или добавить `Tests/AppUpdateChecks.swift` и подключить к `scripts/test.sh`
- Modify: `Sources/IPList/App.swift` для состояния, кнопки и отображения результата

**Interfaces:**
- Produces `AppUpdateStatus: Equatable` с состояниями `upToDate`, `updateAvailable(version: String, url: URL)`, `failed(message: String)`.
- Produces `AppUpdateChecker.check(currentVersion: String, endpoint: URL) async -> AppUpdateStatus`.
- Парсит только опубликованные GitHub Releases; prerelease/draft игнорируются; версии сравниваются численно по dot-компонентам.

- [ ] Написать тесты на равную версию, новую версию, prerelease/draft, повреждённый JSON и HTTP-ошибку через URLProtocol/тестовый transport.
- [ ] Запустить тесты и зафиксировать первоначальное падение.
- [ ] Реализовать URLSession-клиент с timeout, проверкой HTTP 2xx, ограничением ответа и безопасным декодированием.
- [ ] Добавить в настройки кнопку «Проверить обновления», статус/дату последней проверки и `Link` для доступного релиза.
- [ ] Запустить `./scripts/test.sh`, `swift build` и проверить, что refresh источников не изменился.

### Task 2: Явная светлая тема macOS и аудит контраста

**Files:**
- Modify: `Sources/IPList/App.swift` — корневой `.preferredColorScheme(.light)` и семантические цвета для фонов, primary/secondary text, accent, success, warning, error и disabled controls.
- Create: `Tests/ThemeChecks.swift` — проверка палитры/контрастных пар как чистых значений.
- Modify: `README.md` и `RELEASE_NOTES_1.4.1.md` только после фактической проверки UI.

**Interfaces:**
- Produces a single `IPListTheme` palette with named roles, usable by catalog, manual IP, history, export, settings, sheets, alerts, menu-bar status and empty/loading/error states.

- [ ] Составить таблицу ролей цвета и тесты контраста WCAG AA для обычного и мелкого текста.
- [ ] Перевести hard-coded `.secondary`, `.teal`, `.orange`, `.red`, `.green` и фоновые стили на роли там, где системная роль не гарантирует нужную читаемость в светлой схеме.
- [ ] Включить светлую схему на уровне окна и проверить все страницы, формы, sheets, alerts, disabled/loading/error состояния.
- [ ] Собрать приложение и провести визуальный desktop-аудит; отметить непроверенные состояния явно.

### Task 2a: Независимое включение адресов «Мои IP» в macOS-выгрузку

**Files:**
- Modify: `Sources/IPList/CatalogModels.swift` или модель состояния — добавить persisted `isIncludedInExport` для каждой записи «Мои IP», старые записи мигрировать в `true`.
- Modify: `Sources/IPList/App.swift` — показать Toggle/галочку в списке «Мои IP» и считать в JSON/AllowedIPs/AmneziaWG только отмеченные записи.
- Modify: `Tests/StateChecks.swift`, `Tests/CoreChecks.swift` — тесты состояния, миграции и экспорта.

**Interfaces:**
- `ManualEntry.isIncludedInExport: Bool`.
- `Store.setManualIncluded(id: UUID, _ included: Bool)` сохраняет состояние и пересобирает экспорт без удаления записи.
- Все экспортёры используют только `manual.filter(\\.isIncludedInExport)`.

- [ ] Добавить тесты: новая запись отмечена, снятие галочки исключает её из выгрузки, повторное включение возвращает её, остальные записи не меняются.
- [ ] Добавить миграцию старого JSON без поля в `true` и проверить round-trip сохранение.
- [ ] Подключить Toggle к каждой строке «Мои IP», обновлять JSON/AllowedIPs/конфигурации и autosave после переключения.
- [ ] Проверить Targeted/Lite/Full и отсутствие влияния снятия галочки на каталог, историю и саму запись.

### Task 3: Windows update checker and light theme (`codex/windows-1.4.0`)

**Files:**
- Modify: `Windows/src/IPList.Core/` — pure update-checking contract/client and tests.
- Modify: `Windows/src/IPList.App/MainWindow.xaml`, `App.xaml`, `MainWindow.xaml.cs`, view models and settings UI.
- Modify: `Windows/tests/IPList.Core.Tests/` and add UI-level testable palette checks where the existing project permits.

**Interfaces:**
- Windows UI must expose the same update status contract as Task 1 and named light-theme roles equivalent to Task 2.

- [ ] Использовать существующий WPF/.NET 10 target and current Windows branch plan; не создавать второй Windows UI stack.
- [ ] Подключить update checker to GitHub Releases with the same version semantics and error states.
- [ ] Добавить Windows-specific readable controls, dialogs, disabled/error states and contrast tests.
- [ ] Build and run on Windows; attach exact artifact path and verification result.

### Task 3a: Независимое включение адресов «Мои IP» в Windows-выгрузку

**Files:**
- Modify: `Windows/src/IPList.Core/State/AppState.cs` and related persistence models — persisted `IsIncludedInExport` per manual entry, with legacy default `true`.
- Modify: `Windows/src/IPList.App/MainWindow.xaml`, `MainWindow.xaml.cs`, `ViewModels/MainViewModel.cs` — checkbox per «Мои IP» row and export refresh.
- Modify: `Windows/tests/IPList.Core.Tests/` — state, migration, selection and export tests.

**Interfaces:**
- `ManualEntry.IsIncludedInExport: bool`.
- `MainViewModel.SetManualIncludedCommand` changes one flag, persists through the existing coordinator, and never deletes the entry.
- JSON, `AllowedIPs` and AmneziaWG export paths consume only included manual entries.

- [ ] Add tests for default-checked new entries, unchecking/rechecking one entry, preserving other entries, and legacy JSON migration.
- [ ] Bind a visible checkbox to every «Мои IP» row, including disabled/loading/error states, with readable light-theme colors.
- [ ] Verify the checkbox immediately updates autosaved export and all export formats while retaining the unselected record, group and note.
- [ ] Run Windows Core tests and the existing WPF build/CI checks.

## Self-review

- macOS update checking is covered by Tasks 1 and 2; per-entry «Мои IP» inclusion is covered by Task 2a.
- macOS light theme and readability audit are covered by Task 2.
- Windows is explicitly covered by Tasks 3 and 3a in the existing `codex/windows-1.4.0` branch.
- No task changes the existing source refresh transaction.

## IPList 1.5.0 completion plan

### Scope

- macOS 1.5.0: per-entry «Мои IP» selection, GitHub update check, explicit light theme, export-target selector, export validation, safety counter, platform suffix in filenames.
- Windows 1.5.0 (`codex/windows-1.4.0`): the same behavior in WPF, Windows hard limit of 500 normalized routes, per-entry selection, light-theme readability, update check, and target-aware filenames.

### Safety profiles

- Windows: 0–300 dark green, 301–400 green/yellow, 401–500 orange, 501+ red and blocked. The hard limit is enforced again at save time, not only by the counter.
- macOS: 0–500 dark green, 501–2,000 green, 2,001–5,000 orange, 5,001+ red advisory. macOS red remains exportable with a warning.
- The counter uses the exact normalized/collapsed route set used by the exporter and shows catalog, remainder, manual, and final route counts.

### Execution order

- [ ] Finish shared macOS export-target validation and add unit tests for thresholds, invalid routes, `/32`, collapse, and Windows rejection.
- [ ] Add the interactive macOS safety counter and target-aware filename behavior; run full Swift checks and build.
- [ ] Finish Windows target selector, exact counter, hard validation, filename suffix, and light palette; add Core tests.
- [ ] Add Windows update checker UI and testable version comparison/error handling.
- [ ] Review both diffs for duplicated logic, accidental source-refresh changes, unsafe overwrite behavior, and unreadable colors.
- [ ] Run all locally available checks; mark Windows runtime/CI verification as unverified if no Windows SDK is available.

### Critical self-review

The plan is intentionally limited to one shared concept per platform: a pure safety calculation reused by the counter and save-time validator. No route-refresh code is changed, no automatic publication is added, and no extra dependency is introduced. The only unavoidable verification gap is Windows runtime execution on this macOS host; CI remains the authoritative Windows build check.
