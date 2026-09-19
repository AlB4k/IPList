import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers

/// Routes belonging to one catalog entry in the mode currently shown to the
/// person using the app.  Keeping this outside the SwiftUI view makes the
/// search behavior deterministic and independently testable.
func catalogRoutes(for service: CatalogService, mode: ExportMode) -> [String] {
    switch mode {
    case .targeted: return service.targetedAddresses
    case .lite: return service.liteAddresses
    case .full: return service.fullAddresses
    }
}

func catalogMatches(service: CatalogService, query: String, mode: ExportMode) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return true }

    if let searchedNetwork = IPv4Network(needle) {
        return (service.ipRanges + catalogRoutes(for: service, mode: mode)).contains {
            IPv4Network($0)?.intersects(searchedNetwork) == true
        }
    }

    let searchableText = [service.name] + service.domains + service.asn.map { "AS\($0)" }
    return searchableText.contains { $0.localizedCaseInsensitiveContains(needle) }
}

enum ConfigurationOperationRecommendation: Equatable {
    case add
    case bypassOrReplace
}

func recommendedConfigurationOperation(existingRoutes: [String]) -> ConfigurationOperationRecommendation {
    existingRoutes.contains { IPv4Network($0)?.prefix == 0 } ? .bypassOrReplace : .add
}

func configurationNeedsPeerChoice(_ document: AmneziaWGDocument) -> Bool {
    document.peers.count > 1
}

func configurationCanBeSaved(
    document: AmneziaWGDocument,
    peer: Int,
    operation: AllowedIPsOperation,
    routes: [String],
    preserveIPv6: Bool
) -> Bool {
    do {
        let rendered = try document.render(peer: peer, operation: operation, routes: routes, preserveIPv6: preserveIPv6)
        _ = try AmneziaWGDocument.parse(rendered)
        return true
    } catch {
        return false
    }
}

func enrichedConfigurationOutputNames(for inputNames: [String]) -> [String] {
    var occurrences: [String: Int] = [:]
    return inputNames.map { inputName in
        let filename = URL(fileURLWithPath: inputName).lastPathComponent
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let base = stem.isEmpty ? "configuration" : stem
        let key = base.lowercased()
        let occurrence = occurrences[key, default: 0] + 1
        occurrences[key] = occurrence
        return occurrence == 1 ? "\(base)-iplist.conf" : "\(base)-iplist-\(occurrence).conf"
    }
}

struct AllowedIPsExportSummary {
    let text: String
    let routeCount: Int
    let byteCount: Int
}

func allowedIPsExportSummary(_ addresses: Set<String>) -> AllowedIPsExportSummary? {
    let routes = collapseIPv4(addresses.compactMap(IPv4Network.init)).map(\.description)
    guard !routes.isEmpty else { return nil }
    let text = "AllowedIPs = \(routes.joined(separator: ", "))"
    return AllowedIPsExportSummary(text: text, routeCount: routes.count, byteCount: text.lengthOfBytes(using: .utf8))
}

private func allowedIPsRouteCount(in configuration: String) -> Int {
    configuration.split(whereSeparator: \.isNewline).reduce(into: 0) { count, line in
        guard let equals = line.firstIndex(of: "="),
              line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("AllowedIPs") == .orderedSame else {
            return
        }
        let values = line[line.index(after: equals)...]
            .split(separator: ",", omittingEmptySubsequences: true)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        count += values.count
    }
}

private func allowedIPsRouteStrings(in configuration: String) -> [String] {
    configuration.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
        guard let equals = line.firstIndex(of: "="),
              line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("AllowedIPs") == .orderedSame else {
            return []
        }
        return line[line.index(after: equals)...]
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

enum ConfigurationOperation: String, CaseIterable, Identifiable {
    case add
    case replace
    case bypass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .add: return "Добавить к существующим"
        case .replace: return "Заменить выбранными"
        case .bypass: return "Пустить выбранное мимо VPN"
        }
    }

    var operation: AllowedIPsOperation {
        switch self {
        case .add: return .add
        case .replace: return .replace
        case .bypass: return .bypass
        }
    }
}

enum AllowedIPsAction {
    case copy
    case save
    case configure
}

struct ConfigurationInput: Identifiable {
    let id = UUID()
    let url: URL
    let source: String
    let document: AmneziaWGDocument
    var peer = 0
}

struct ConfigurationWriteResult: Identifiable {
    let id = UUID()
    let name: String
    let success: Bool
    let message: String
}

@MainActor final class Store: ObservableObject {
    @Published var state = AppState()
    @Published var busy = false
    @Published var testingSources = false
    @Published var sourceChecks: [SourceCheck] = []
    @Published var selectedProfileID: UUID?
    @Published var message = "Выберите режим выгрузки и проверьте источники."
    @Published var error: String?
    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("IPList")
    var timer: Timer?
    var nextRetry = Date.distantPast
    private var rawPreMigrationState: Data?
    var exportReady: Bool {
        state.exportReady
    }
    init() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                let backup = folder.appendingPathComponent("state-before-v1.1.json")
                if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
                state = try JSONDecoder().decode(AppState.self, from: data)
                if state.stateVersion < 14 { rawPreMigrationState = data }
            }
        } catch { self.error = "Не удалось прочитать сохранённые данные: \(error.localizedDescription)" }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkSchedule() } }
        applyIconVisibility()
        Task { checkSchedule() }
    }
    func checkSchedule() {
        let lastSuccessfulRefresh = state.lastChecks.values.max() ?? state.lastCheck
        if state.automatic && !busy && !testingSources && Date() >= nextRetry && Date().timeIntervalSince(lastSuccessfulRefresh ?? .distantPast) >= Double(state.intervalHours) * 3600 { Task { await refresh() } }
    }
    func persist() {
        do {
            try StatePersistence.write(state, to: folder, rawPreMigrationState: rawPreMigrationState)
            if exportReady { try exportData(state.export).write(to: folder.appendingPathComponent("amnezia-direct.json"), options: .atomic) }
        } catch { self.error = "Не удалось сохранить данные: \(error.localizedDescription)" }
    }
    func record(before: Set<String>, reason: String) {
        let after = state.export
        let added = after.subtracting(before).sorted(), removed = before.subtracting(after).sorted()
        guard !added.isEmpty || !removed.isEmpty else { return }
        state.changes.insert(Change(added: added, removed: removed, reason: reason), at: 0)
        state.changes = Array(state.changes.prefix(100))
    }
    func select(_ ids: [String], enabled: Bool) {
        let before = state.export
        if state.catalog != nil {
            state.setCatalogSelection(ids, enabled: enabled)
        } else {
            for id in ids { if enabled { state.selected.insert(id) } else { state.selected.remove(id) } }
            state.selectionInitialized = true
            state.selectAllByDefault = !state.services.isEmpty && Set(state.services.map(\.id)).isSubset(of: state.selected)
        }
        selectedProfileID = nil
        record(before: before, reason: "Изменён выбор сервисов"); persist()
    }
    func selectAll(_ enabled: Bool) {
        let before = state.export
        if let catalog = state.catalog {
            state.setCatalogSelection(catalog.services.map(\.id), enabled: enabled)
            state.selectedUnassignedModes = enabled ? Set(CatalogRouteMode.allCases) : []
            state.manualEnabled = enabled
        } else {
            state.selected = enabled ? Set(state.services.map(\.id)) : []
            state.selectedCatalogIDs = state.selected
            state.selectAllByDefault = enabled
            state.selectionInitialized = true
            state.manualEnabled = enabled
        }
        selectedProfileID = nil
        record(before: before, reason: enabled ? "Выбраны все ресурсы" : "Снят выбор всех ресурсов"); persist()
    }
    func setUnassignedEnabled(_ enabled: Bool, for mode: ExportMode) {
        let before = state.export
        state.setUnassignedSelection(mode, enabled: enabled)
        selectedProfileID = nil
        record(before: before, reason: "Изменён выбор «Остальных сетей источника»")
        persist()
    }
    func setMode(_ mode: ExportMode) {
        guard !busy else { return }
        state.mode = mode; selectedProfileID = nil; nextRetry = .distantPast; persist()
        message = exportReady ? "Режим: \(mode.title). В выгрузке \(state.export.count) адресов." : "Для режима «\(mode.title)» нажмите «Проверить сейчас». Предыдущая автоматическая выгрузка сохранена до загрузки."
    }
    func setManualEnabled(_ enabled: Bool) {
        let before = state.export; state.manualEnabled = enabled; selectedProfileID = nil
        record(before: before, reason: "Изменена категория «Мои IP»"); persist()
    }
    func saveProfile(name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { error = "Введите название профиля"; return }
        guard !state.profiles.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else { error = "Профиль с таким именем уже есть. Используйте обновление профиля."; return }
        state.saveProfile(name: clean)
        selectedProfileID = state.profiles.last?.id; persist(); message = "Профиль «\(clean)» сохранён."
    }
    func updateProfile(_ id: UUID) {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
        state.profiles[index] = SelectionProfile(
            id: id,
            name: state.profiles[index].name,
            selected: state.selectedCatalogIDs,
            selectedUnassignedModes: state.selectedUnassignedModes,
            mode: state.mode,
            manualEnabled: state.manualEnabled,
            selectAllByDefault: state.selectAllByDefault
        )
        selectedProfileID = id; persist(); message = "Профиль обновлён."
    }
    func applyProfile(_ id: UUID) {
        guard !busy, let profile = state.profiles.first(where: { $0.id == id }) else { return }
        let before = state.export
        guard state.applyProfile(id: id) else { return }
        selectedProfileID = id; nextRetry = .distantPast
        record(before: before, reason: "Применён профиль «\(profile.name)»"); persist()
        message = "Профиль «\(profile.name)» применён." + (exportReady ? "" : " Загрузите выбранный список кнопкой «Проверить сейчас».")
    }
    func deleteProfile(_ id: UUID) {
        state.profiles.removeAll { $0.id == id }; if selectedProfileID == id { selectedProfileID = nil }; persist()
    }
    func markChangesSeen() {
        guard state.hasUnseenChanges else { return }
        state.hasUnseenChanges = false; persist()
    }
    func setDockIconVisible(_ visible: Bool) {
        guard visible != state.dockIconVisible else { return }
        state.dockIconVisible = visible
        if !visible && !state.menuBarIconVisible { state.menuBarIconVisible = true }
        applyIconVisibility(); persist()
    }
    func setMenuBarIconVisible(_ visible: Bool) {
        guard visible != state.menuBarIconVisible else { return }
        state.menuBarIconVisible = visible
        if !visible && !state.dockIconVisible { state.dockIconVisible = true }
        applyIconVisibility(); persist()
    }
    func applyIconVisibility() {
        NSApp.setActivationPolicy(state.dockIconVisible ? .regular : .accessory)
    }
    func addManual(_ text: String, groupID: UUID? = nil) {
        let values = text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" }).map(String.init)
        guard !values.isEmpty else { return }
        let invalid = values.filter { normalizeIP($0) == nil }
        guard invalid.isEmpty else { error = "Некорректные IPv4 / CIDR: " + invalid.joined(separator: ", "); return }
        let before = state.export
        let existing = Set(state.manual.map(\.address))
        let normalized = Array(Set(values.compactMap(normalizeIP)))
        let additions = normalized.filter { !existing.contains($0) }.sorted().map { ManualEntry(address: $0, groupID: groupID) }
        state.manual = (state.manual + additions).sorted { $0.address < $1.address }
        record(before: before, reason: "Добавлены мои IP"); persist()
    }
    func removeManual(id: UUID) {
        let before = state.export
        state.manual.removeAll { $0.id == id }
        record(before: before, reason: "Удалён мой IP"); persist()
    }
    func updateManualNote(id: UUID, note: String) {
        guard let index = state.manual.firstIndex(where: { $0.id == id }) else { return }
        state.manual[index].note = note; persist()
    }
    func setManualGroup(id: UUID, groupID: UUID?) {
        guard let index = state.manual.firstIndex(where: { $0.id == id }) else { return }
        state.manual[index].groupID = groupID; persist()
    }
    @discardableResult func addGroup(name: String) -> Bool {
        let ok = state.addGroup(name: name)
        if ok { persist() } else { error = "Группа с таким именем уже есть или имя пустое." }
        return ok
    }
    func renameGroup(id: UUID, name: String) { state.renameGroup(id: id, name: name); persist() }
    func deleteGroup(id: UUID) { state.deleteGroup(id: id); persist() }
    func testSources() async {
        guard !busy && !testingSources else { return }
        testingSources = true; sourceChecks = []; defer { testingSources = false }
        message = "Проверяю источники: HTTPS, формат данных и доступность резервных ссылок…"
        sourceChecks = await CatalogLoader().testSources(source: state.sourceURL, base: state.categoryBaseURL, liteSource: state.liteSourceURL, fullSource: state.fullSourceURL)
        let failed = sourceChecks.filter { !$0.success }.count
        message = failed == 0 ? "Все проверенные источники доступны. Тест не меняет списки IP." : "Недоступно адресов источников: \(failed). Подробности — в результатах проверки."
    }
    func refresh() async {
        guard !busy && !testingSources else { return }; busy = true; defer { busy = false }
        error = nil
        message = "Обновляю каталог, три списка адресов, DNS и RIPEstat…"
        do {
            let before = state.export
            let previousSources = sourceRoutes()
            let wasFirstRefresh = state.lastChecks.isEmpty && state.lastCheck == nil
            let transaction = try await RefreshPipeline.live().run(RefreshRequest(state: state))
            try Task.checkCancellation()
            guard state.applyRefreshTransaction(transaction) else {
                throw RefreshPipelineError.validationFailure(transaction.sourceChecks, "Полученный каталог нельзя безопасно применить.")
            }
            sourceChecks = transaction.sourceChecks
            nextRetry = .distantPast
            record(before: before, reason: wasFirstRefresh ? "Первая загрузка всех источников" : "Обновление всех источников")
            let changedSources = recordSourceChanges(before: previousSources, after: transaction.sourceRoutes)
            if !wasFirstRefresh && (changedSources.added > 0 || changedSources.removed > 0 || before != state.export) {
                let content = UNMutableNotificationContent()
                content.title = "IPList: список изменился"
                content.body = "Источники: +\(changedSources.added), −\(changedSources.removed). Выгрузка: +\(state.export.subtracting(before).count), −\(before.subtracting(state.export).count)."
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
            persist()
            let activeCount = transaction.sourceRoutes[state.mode]?.count ?? state.export.count
            message = "Обновлены все источники. «\(state.mode.title)»: \(activeCount) IPv4 / диапазонов; в выгрузке: \(state.export.count)."
        } catch {
            if let refreshError = error as? RefreshPipelineError { sourceChecks = refreshError.sourceChecks }
            nextRetry = Date().addingTimeInterval(15 * 60)
            self.error = error.localizedDescription
            message = "Обновление не выполнено. Предыдущие данные сохранены. Проверьте источники в настройках."
        }
    }

    private func sourceRoutes() -> [ExportMode: Set<String>] {
        if let catalog = state.catalog {
            return [
                .targeted: Set(catalog.services.flatMap(\.targetedAddresses)).union(state.unassignedRoutes[.targeted] ?? []),
                .lite: Set(catalog.services.flatMap(\.liteAddresses)).union(state.unassignedRoutes[.lite] ?? []),
                .full: Set(catalog.services.flatMap(\.fullAddresses)).union(state.unassignedRoutes[.full] ?? [])
            ]
        }
        return [
            .targeted: Set(state.services.flatMap(\.addresses)),
            .lite: state.liteAddresses,
            .full: state.fullAddresses
        ]
    }

    @discardableResult private func recordSourceChanges(before: [ExportMode: Set<String>], after: [ExportMode: Set<String>]) -> (added: Int, removed: Int) {
        var totalAdded = 0
        var totalRemoved = 0
        for mode in ExportMode.allCases {
            let added = (after[mode] ?? []).subtracting(before[mode] ?? []).sorted()
            let removed = (before[mode] ?? []).subtracting(after[mode] ?? []).sorted()
            guard !added.isEmpty || !removed.isEmpty else { continue }
            totalAdded += added.count
            totalRemoved += removed.count
            state.changes.insert(Change(added: added, removed: removed, reason: "Источник: \(mode.title)"), at: 0)
            state.hasUnseenChanges = true
        }
        state.changes = Array(state.changes.prefix(100))
        return (totalAdded, totalRemoved)
    }
    func exportFile() {
        guard exportReady else { error = "Сначала загрузите данные выбранного режима кнопкой «Проверить сейчас»."; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "amnezia-\(state.mode.rawValue).json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try exportData(state.export).write(to: url, options: .atomic); message = "Экспортировано \(state.export.count) адресов в \(url.lastPathComponent)." } catch { self.error = error.localizedDescription }
    }
    var allowedIPsSummary: AllowedIPsExportSummary? {
        allowedIPsExportSummary(state.export)
    }
    func copyAllowedIPs() {
        guard let summary = allowedIPsSummary else {
            error = "Нет выбранных IPv4 / CIDR для строки AllowedIPs. Выберите сервис, «Остальные сети источника» или «Мои IP»."
            return
        }
        copyToPasteboard(summary.text)
        message = "Скопирована строка AllowedIPs: \(summary.routeCount) маршрутов, \(summary.byteCount) байт."
    }
    func saveAllowedIPs() {
        guard let summary = allowedIPsSummary else {
            error = "Нет выбранных IPv4 / CIDR для строки AllowedIPs. Выберите сервис, «Остальные сети источника» или «Мои IP»."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "allowed-ips-\(state.mode.rawValue).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(summary.text.utf8).write(to: url, options: .atomic)
            message = "Сохранена строка AllowedIPs: \(summary.routeCount) маршрутов, \(summary.byteCount) байт."
        } catch {
            self.error = "Не удалось сохранить строку AllowedIPs: \(error.localizedDescription)"
        }
    }
    func chooseConfigurationInputs() -> (inputs: [ConfigurationInput], issues: [ConfigurationWriteResult]) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return ([], []) }

        var inputs: [ConfigurationInput] = []
        var issues: [ConfigurationWriteResult] = []
        for url in panel.urls.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            do {
                guard let source = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                let document = try AmneziaWGDocument.parse(source)
                inputs.append(ConfigurationInput(url: url, source: source, document: document))
            } catch {
                issues.append(ConfigurationWriteResult(name: url.lastPathComponent, success: false,
                                                        message: "Не удалось проверить конфигурацию: \(error.localizedDescription)"))
            }
        }
        if !inputs.isEmpty {
            message = "Подготовлено конфигураций AmneziaWG: \(inputs.count). Исходные файлы не изменяются."
        } else if !issues.isEmpty {
            error = "Не удалось подготовить конфигурации: " + issues.map { "\($0.name) — \($0.message)" }.joined(separator: "\n")
        }
        return (inputs, issues)
    }
    func chooseConfigurationOutputFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать папку"
        return panel.runModal() == .OK ? panel.url : nil
    }
    func saveEnrichedConfigurations(
        _ inputs: [ConfigurationInput],
        operation: ConfigurationOperation,
        preserveIPv6: Bool,
        to destination: URL
    ) -> [ConfigurationWriteResult] {
        guard let summary = allowedIPsSummary else {
            error = "Нет выбранных IPv4 / CIDR для строки AllowedIPs."
            return []
        }
        let routes = state.export.sorted()
        let outputNames = enrichedConfigurationOutputNames(for: inputs.map { $0.url.lastPathComponent })
        let fileManager = FileManager.default
        struct WritePlan {
            let input: ConfigurationInput
            let output: URL
            let data: Data
        }
        var plans: [WritePlan] = []
        var preflightFailures: [ConfigurationWriteResult] = []
        for (input, outputName) in zip(inputs, outputNames) {
            let output = destination.appendingPathComponent(outputName)
            do {
                guard input.url.standardizedFileURL != output.standardizedFileURL else {
                    throw CocoaError(.fileWriteFileExists)
                }
                guard !fileManager.fileExists(atPath: output.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                let rendered = try input.document.render(peer: input.peer, operation: operation.operation,
                                                         routes: routes, preserveIPv6: preserveIPv6)
                _ = try AmneziaWGDocument.parse(rendered)
                plans.append(WritePlan(input: input, output: output, data: Data(rendered.utf8)))
            } catch {
                preflightFailures.append(ConfigurationWriteResult(
                    name: input.url.lastPathComponent,
                    success: false,
                    message: "Проверка перед сохранением не пройдена: \(error.localizedDescription)"
                ))
            }
        }
        guard preflightFailures.isEmpty else {
            error = "Конфигурации не сохранены: исправьте отмеченные проверки. Исходные файлы не изменены."
            return preflightFailures
        }

        var results: [ConfigurationWriteResult] = []
        for plan in plans {
            let temporary = destination.appendingPathComponent(".iplist-\(UUID().uuidString).tmp")
            do {
                try plan.data.write(to: temporary, options: .atomic)
                try fileManager.moveItem(at: temporary, to: plan.output)
                results.append(ConfigurationWriteResult(name: plan.output.lastPathComponent, success: true,
                                                        message: "Проверено и сохранено отдельно."))
            } catch {
                try? fileManager.removeItem(at: temporary)
                results.append(ConfigurationWriteResult(name: plan.input.url.lastPathComponent, success: false,
                                                        message: "Не удалось создать новый файл: \(error.localizedDescription)"))
            }
        }
        let saved = results.filter(\.success).count
        message = "Создано новых конфигураций AmneziaWG: \(saved) из \(plans.count), \(summary.routeCount) маршрутов в текущей выгрузке."
        return results
    }
    func importFile() -> [String] {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return [] }
        do {
            let rows = try JSONDecoder().decode([AmneziaEntry].self, from: Data(contentsOf: url))
            let result = Array(Set(rows.flatMap(\.addresses))).sorted()
            message = "Импорт: \(rows.count) записей, \(result.count) IPv4 / CIDR. Домены без IP и IPv6 пропущены."
            return result
        } catch { self.error = error.localizedDescription; return [] }
    }
    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    func copyManualAddresses() {
        guard !state.manual.isEmpty else { return }
        copyToPasteboard(state.manual.map(\.address).sorted().joined(separator: "\n"))
        message = "Скопировано адресов «Мои IP»: \(state.manual.count)."
    }
    func copyManualAddress(_ entry: ManualEntry) {
        copyToPasteboard(entry.address)
        message = "Скопирован адрес: \(entry.address)."
    }
}

#if !TASK7_CHECKS
@main struct IPListApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup("IPList • Мимо VPN") { ContentView().environmentObject(store).frame(minWidth: 1020, minHeight: 700) }
            .windowStyle(.hiddenTitleBar)
        MenuBarExtra(isInserted: Binding(get: { store.state.menuBarIconVisible }, set: { store.setMenuBarIconVisible($0) })) {
            Text("В выгрузке: \(store.state.export.count) IP")
            Text(lastUpdateText).foregroundStyle(.secondary)
            if store.state.hasUnseenChanges { Text("Есть новые изменения адресов").foregroundStyle(.orange) }
            Divider()
            Button("Открыть IPList") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
            Button("Проверить сейчас") { Task { await store.refresh() } }.disabled(store.busy || store.testingSources)
            Button("Экспортировать…") { store.exportFile() }.disabled(!store.exportReady)
            Divider()
            Button(store.testingSources ? "Проверяю источники…" : "Проверить источники") { Task { await store.testSources() } }.disabled(store.busy || store.testingSources)
            sourceStatusRows
            Divider()
            Button("Завершить IPList") { NSApp.terminate(nil) }
        } label: {
            Label("IPList", systemImage: store.state.hasUnseenChanges ? "bell.badge.fill" : "arrow.triangle.branch")
        }
    }

    private var lastUpdateText: String {
        guard let date = store.state.lastCheck(for: store.state.mode) else { return "Ещё не обновлялось" }
        return "Обновлено: " + date.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder private var sourceStatusRows: some View {
        if store.sourceChecks.isEmpty {
            HStack(spacing: 6) {
                Circle().fill(Color.gray).frame(width: 8, height: 8)
                Text("Источники ещё не проверялись")
            }
        } else {
            ForEach(store.sourceChecks) { check in
                HStack(spacing: 6) {
                    Circle().fill(check.success ? Color.green : Color.red).frame(width: 8, height: 8)
                    Text(check.name)
                }
            }
        }
    }
}
#endif

@MainActor final class ViewState: ObservableObject {
    @Published var page = "Каталог"
    @Published var search = ""
    @Published var manual = ""
    @Published var profileName = ""
    @Published var importRows: [String] = []
    @Published var importSelection: Set<String> = []
    @Published var showImport = false
    @Published var expandedCategories: Set<String> = []
    @Published var manualGroupID: UUID?
    @Published var newGroupName = ""
    @Published var editingGroupID: UUID?
    @Published var editingGroupName = ""
    @Published var showConfigurationSheet = false
    @Published var configurationInputs: [ConfigurationInput] = []
    @Published var configurationResults: [ConfigurationWriteResult] = []
    @Published var configurationOperation: ConfigurationOperation = .bypass
    @Published var preserveConfigurationIPv6 = true
    @Published var configurationOutputFolder: URL?
    @Published var pendingAllowedIPsAction: AllowedIPsAction?
    @Published var showFullRouteWarning = false
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @StateObject private var ui = ViewState()
    private static let appIcon: NSImage = NSApplication.shared.applicationIconImage

    private let pages = ["Каталог", "Мои IP", "Изменения", "Выгрузка", "Настройки"]
    private let pageIcons: [String: String] = [
        "Каталог": "list.bullet.rectangle.portrait",
        "Мои IP": "network",
        "Изменения": "clock.arrow.circlepath",
        "Выгрузка": "square.and.arrow.up",
        "Настройки": "gearshape"
    ]
    private let categoryIcons: [String: String] = [
        "Банки и финансы": "banknote",
        "Безопасность": "lock.shield",
        "Государство": "building.columns",
        "Карты": "map",
        "Магазины": "cart",
        "Маркетплейсы": "bag",
        "Медицина": "cross.case",
        "Поиск и технологии": "magnifyingglass",
        "Почта": "envelope",
        "Прочие ресурсы": "square.grid.2x2",
        "Развлечения": "gamecontroller",
        "СМИ": "newspaper",
        "Социальные сети": "person.2",
        "Транспорт и путешествия": "airplane"
    ]
    private func pageIcon(_ page: String) -> String { pageIcons[page] ?? "circle" }
    private func categoryIcon(_ category: String) -> String { categoryIcons[category] ?? "folder" }
    private var scheduleSummary: String {
        store.state.automatic ? "Обновление настроено на: каждые \(store.state.intervalHours) ч" : "Обновление настроено на: вручную"
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 10) {
                    Image(nsImage: Self.appIcon)
                        .resizable().frame(width: 72, height: 72)
                    Text("IPList").font(.title.bold()).foregroundStyle(Color.accentColor)
                }.frame(maxWidth: .infinity)
                Text("Ваш маршрут мимо VPN").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
                List(pages, id: \.self, selection: $ui.page) { Label($0, systemImage: pageIcon($0)).padding(.vertical, 7) }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(store.state.export.count)").font(.system(size: 36, weight: .semibold, design: .rounded))
                    Text("IP и диапазонов в выгрузке").foregroundStyle(.secondary)
                    Text(store.state.mode.title).font(.caption).foregroundStyle(.teal)
                }.padding(.top, 8)
            }.padding().navigationSplitViewColumnWidth(245)
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading) { Label(ui.page, systemImage: pageIcon(ui.page)).font(.largeTitle.bold()); Text(subtitle).foregroundStyle(.secondary) }
                    Spacer()
                    if store.busy { ProgressView().controlSize(.small) }
                    Button { Task { await store.refresh() } } label: { Label("Проверить сейчас", systemImage: "arrow.clockwise") }.disabled(store.busy || store.testingSources)
                    Button("Экспорт…") { store.exportFile() }.buttonStyle(.borderedProminent).disabled(!store.exportReady)
                }
                Group {
                    if ui.page == "Каталог" { catalog }
                    else if ui.page == "Мои IP" { manualView }
                    else if ui.page == "Изменения" { history }
                    else if ui.page == "Выгрузка" { preview }
                    else { settings }
                }
                Spacer(minLength: 0)
                Divider()
                Text(store.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(24)
        }
        .alert("IPList", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("Полный список может не запуститься на смартфоне", isPresented: $ui.showFullRouteWarning) {
            Button("Отмена", role: .cancel) { ui.pendingAllowedIPsAction = nil }
            Button("Продолжить") {
                if let action = ui.pendingAllowedIPsAction {
                    ui.pendingAllowedIPsAction = nil
                    performAllowedIPsAction(action)
                }
            }
        } message: {
            let summary = store.allowedIPsSummary
            Text("В режиме «Полный российский сегмент» будет использовано \(summary?.routeCount ?? 0) маршрутов (\(summary?.byteCount ?? 0) байт). Мобильный клиент может не поднять туннель на таком объёме. Для смартфона выберите Lite или несколько сервисов. Продолжить можно для компьютера или эксперимента.")
        }
        .sheet(isPresented: $ui.showImport) { importSheet }
        .sheet(isPresented: $ui.showConfigurationSheet) { configurationSheet }
        .onChange(of: ui.page) { page in if page == "Изменения" { store.markChangesSeen() } }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 6) {
                    Image(nsImage: Self.appIcon)
                        .resizable().frame(width: 20, height: 20)
                    HStack(spacing: 0) {
                        Text("IPList • Мимо VPN • ")
                        Text(scheduleSummary).foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    private var subtitle: String {
        switch ui.page {
        case "Каталог": return "Категории свёрнуты; поиск показывает подходящие ресурсы"
        case "Мои IP": return "IPv4 и CIDR, которые должны идти напрямую"
        case "Изменения": return "Добавленные и удалённые адреса · последние 100 событий"
        case "Выгрузка": return store.state.mode.detail
        default: return "Режим выгрузки, источники и расписание"
        }
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 12) {
            modePicker
            HStack {
                TextField("Поиск: сервис, домен, ASN, IP или CIDR", text: $ui.search).textFieldStyle(.roundedBorder)
                Toggle("Выбрать всё", isOn: Binding(get: { allSelected }, set: { store.selectAll($0) }))
                    .toggleStyle(.checkbox).frame(width: 155).disabled(store.busy)
                Text("\(selectedCount)/\(catalogServices.count)").foregroundStyle(.secondary).font(.caption)
            }
            if catalogServices.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "network").font(.system(size: 56)).foregroundStyle(.teal)
                    Text("Начните с обновления каталога").font(.title2)
                    Text("После загрузки все категории будут выбраны автоматически.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if visibleServiceCount == 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Ничего не найдено", systemImage: "magnifyingglass")
                                .font(.headline)
                            Text("Ищите по названию, домену, AS-номеру, IP или CIDR. Каталог: \(catalogFreshnessText).")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }
                    ForEach(categories, id: \.self) { category in
                        let all = catalogServices(in: category)
                        let visible = matching(all)
                        if !visible.isEmpty {
                            DisclosureGroup(isExpanded: Binding(get: { ui.expandedCategories.contains(category) }, set: { value in if value { ui.expandedCategories.insert(category) } else { ui.expandedCategories.remove(category) } })) {
                                ForEach(visible) { service in serviceRow(service) }
                            } label: {
                                categoryHeader(category, all: all)
                            }
                        }
                    }
                    Section("Другие адреса") {
                        if !unassignedRoutes.isEmpty {
                            Toggle("Остальные сети источника", isOn: Binding(
                                get: { selectedUnassigned },
                                set: { store.setUnassignedEnabled($0, for: store.state.mode) }
                            ))
                            .toggleStyle(.checkbox)
                            .disabled(store.busy)
                            Text("\(unassignedRoutes.count) маршрутов текущего режима не относятся к сервису каталога.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Мои IP", isOn: Binding(get: { store.state.manualEnabled }, set: { store.setManualEnabled($0) }))
                            .toggleStyle(.checkbox)
                            .disabled(store.busy)
                        Text(store.state.manual.isEmpty ? "Добавьте адреса на странице «Мои IP»." : "\(store.state.manual.count) пользовательских адресов.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: ui.search) { _ in
            if ui.search.isEmpty { ui.expandedCategories.removeAll() }
            else { ui.expandedCategories = Set(categories.filter { !matching(catalogServices(in: $0)).isEmpty }) }
        }
    }

    private func categoryHeader(_ category: String, all: [CatalogService]) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { all.allSatisfy { selectedCatalogIDs.contains($0.id) } }, set: { store.select(all.map(\.id), enabled: $0) })) { Label(category, systemImage: categoryIcon(category)).font(.headline) }.toggleStyle(.checkbox).disabled(store.busy)
            Spacer()
            Text("\(all.filter { selectedCatalogIDs.contains($0.id) }.count)/\(all.count)").font(.caption).foregroundStyle(.secondary)
            Button("Все") { store.select(all.map(\.id), enabled: true) }.buttonStyle(.borderless).font(.caption).disabled(store.busy)
            Button("Снять") { store.select(all.map(\.id), enabled: false) }.buttonStyle(.borderless).font(.caption).disabled(store.busy)
        }
    }

    private func serviceRow(_ service: CatalogService) -> some View {
        let routes = catalogRoutes(for: service, mode: store.state.mode)
        return DisclosureGroup {
            Text(service.domains.isEmpty ? "Домены не указаны в каталоге" : service.domains.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if !service.asn.isEmpty { Text(service.asn.map { "AS\($0)" }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            Text(routes.isEmpty ? "В этом режиме адресов нет" : routes.joined(separator: ", ")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        } label: {
            Toggle(isOn: Binding(get: { selectedCatalogIDs.contains(service.id) }, set: { store.select([service.id], enabled: $0) })) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.name)
                        Text("\(routes.count) маршрутов · \(serviceFreshnessText(service))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !service.asn.isEmpty { Text(service.asn.map { "AS\($0)" }.joined(separator: ", ")).foregroundStyle(.secondary).font(.caption) }
                }
            }.toggleStyle(.checkbox).disabled(store.busy)
        }.padding(.vertical, 3)
    }

    private var catalogServices: [CatalogService] {
        if let catalog = store.state.catalog { return catalog.services }
        return store.state.services.map {
            CatalogService(id: $0.id, name: $0.name, category: $0.category, domains: $0.domains, asn: $0.asn, targetedAddresses: $0.addresses)
        }
    }
    private var selectedCatalogIDs: Set<String> { store.state.catalog == nil ? store.state.selected : store.state.selectedCatalogIDs }
    private var categories: [String] { Array(Set(catalogServices.map(\.category))).sorted() }
    private func catalogServices(in category: String) -> [CatalogService] { catalogServices.filter { $0.category == category } }
    private func matching(_ services: [CatalogService]) -> [CatalogService] {
        services.filter { catalogMatches(service: $0, query: ui.search, mode: store.state.mode) }
    }
    private var visibleServiceCount: Int { categories.reduce(0) { $0 + matching(catalogServices(in: $1)).count } }
    private var selectedCount: Int { catalogServices.filter { selectedCatalogIDs.contains($0.id) }.count }
    private var selectedUnassigned: Bool { store.state.selectedUnassignedModes.contains(CatalogRouteMode(rawValue: store.state.mode.rawValue)!) }
    private var unassignedRoutes: [String] { store.state.unassignedRoutes[CatalogRouteMode(rawValue: store.state.mode.rawValue)!] ?? [] }
    private var allSelected: Bool {
        !catalogServices.isEmpty && selectedCount == catalogServices.count &&
            store.state.selectedUnassignedModes == Set(CatalogRouteMode.allCases) && store.state.manualEnabled
    }
    private var catalogFreshnessText: String {
        let date = store.state.catalog?.loadedAt.map { " от \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        switch store.state.catalog?.freshness {
        case .remote: return "загружен из источника\(date)"
        case .cached: return "используется сохранённая проверенная копия\(date)"
        case nil: return "ещё не загружен"
        }
    }
    private func serviceFreshnessText(_ service: CatalogService) -> String {
        switch store.state.cachedEnrichment?[service.id]?.freshness {
        case .fresh: return "DNS/ASN: свежие"
        case .cached: return "DNS/ASN: из кэша"
        case .stale: return "DNS/ASN: сохранённые"
        case .bundled: return "DNS/ASN: встроенный снимок"
        case nil: return catalogFreshnessText
        }
    }

    private struct ManualSection: Identifiable { var id: String; var name: String; var entries: [ManualEntry] }

    private var manualGroupSections: [ManualSection] {
        guard !store.state.manual.isEmpty else { return [] }
        var sections: [ManualSection] = store.state.manualGroups.compactMap { group in
            let entries = store.state.manual.filter { $0.groupID == group.id }
            return entries.isEmpty ? nil : ManualSection(id: group.id.uuidString, name: group.name, entries: entries)
        }
        let ungrouped = store.state.manual.filter { $0.groupID == nil }
        if !ungrouped.isEmpty { sections.append(ManualSection(id: "none", name: "Без группы", entries: ungrouped)) }
        return sections
    }

    private var manualView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Включать «Мои IP» в выгрузку", isOn: Binding(get: { store.state.manualEnabled }, set: { store.setManualEnabled($0) }))
            HStack {
                TextField("Например: 77.88.55.55, 192.0.2.0/24", text: $ui.manual).textFieldStyle(.roundedBorder)
                Picker("", selection: $ui.manualGroupID) {
                    Text("Без группы").tag(UUID?.none)
                    ForEach(store.state.manualGroups) { group in Text(group.name).tag(Optional(group.id)) }
                }.labelsHidden().frame(width: 180)
            }
            HStack {
                Button("Добавить") { store.addManual(ui.manual, groupID: ui.manualGroupID); if store.error == nil { ui.manual = "" } }
                Button("Импорт из Amnezia…") { ui.importRows = store.importFile(); ui.importSelection = []; ui.showImport = !ui.importRows.isEmpty }
                Spacer()
                Button { store.copyManualAddresses() } label: { Label("Копировать все", systemImage: "doc.on.doc") }.disabled(store.state.manual.isEmpty)
            }
            Text("IPv4 / CIDR через пробел или запятую. Адрес подсети нормализуется по маске. Группа применяется ко всем адресам, добавленным за раз.").font(.caption).foregroundStyle(.secondary)

            groupManagementView

            List {
                ForEach(manualGroupSections) { section in
                    Section(section.name) {
                        ForEach(section.entries) { entry in manualRow(entry) }
                    }
                }
            }
        }
    }

    private var groupManagementView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Новая группа, например «VPS-сервера»", text: $ui.newGroupName).textFieldStyle(.roundedBorder)
                Button("Добавить группу") { if store.addGroup(name: ui.newGroupName) { ui.newGroupName = "" } }
            }
            ForEach(store.state.manualGroups) { group in
                HStack {
                    if ui.editingGroupID == group.id {
                        TextField("Название группы", text: $ui.editingGroupName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { store.renameGroup(id: group.id, name: ui.editingGroupName); ui.editingGroupID = nil }
                        Button("Готово") { store.renameGroup(id: group.id, name: ui.editingGroupName); ui.editingGroupID = nil }
                    } else {
                        Text(group.name).font(.caption)
                        Spacer()
                        Button("Переименовать") { ui.editingGroupID = group.id; ui.editingGroupName = group.name }.buttonStyle(.borderless).font(.caption)
                    }
                    Button(role: .destructive) { store.deleteGroup(id: group.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
        }
    }

    private func manualRow(_ entry: ManualEntry) -> some View {
        HStack {
            Text(entry.address).font(.system(.body, design: .monospaced)).frame(minWidth: 180, alignment: .leading)
            TextField("Примечание", text: Binding(get: { entry.note }, set: { store.updateManualNote(id: entry.id, note: $0) }))
                .textFieldStyle(.roundedBorder)
            Picker("", selection: Binding(get: { entry.groupID }, set: { store.setManualGroup(id: entry.id, groupID: $0) })) {
                Text("Без группы").tag(UUID?.none)
                ForEach(store.state.manualGroups) { group in Text(group.name).tag(Optional(group.id)) }
            }.labelsHidden().frame(width: 160)
            Button { store.copyManualAddress(entry) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
            Button(role: .destructive) { store.removeManual(id: entry.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }

    private var history: some View {
        List {
            if store.state.changes.isEmpty { Text("Изменений пока нет").foregroundStyle(.secondary) }
            ForEach(store.state.changes) { change in
                DisclosureGroup {
                    Text((change.added.map { "+ " + $0 } + change.removed.map { "− " + $0 }).joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                } label: {
                    VStack(alignment: .leading) { HStack { Text(change.reason); Spacer(); Text("+\(change.added.count)").foregroundStyle(.green); Text("−\(change.removed.count)").foregroundStyle(.red) }; Text(change.date.formatted()).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            modePicker
            Toggle("Включать «Мои IP» в выгружаемый файл", isOn: Binding(get: { store.state.manualEnabled }, set: { store.setManualEnabled($0) }))
            Text(store.state.mode.detail)
            Text("В AmneziaVPN выберите режим «Адреса из списка НЕ должны использовать VPN», затем импортируйте JSON.").font(.caption).foregroundStyle(.secondary)
            Text("Во всех режимах учитываются выбранные сервисы, «Остальные сети источника» и включённые «Мои IP». Общая сеть остаётся, пока её использует хотя бы один выбранный сервис.").font(.caption).foregroundStyle(.secondary)
            allowedIPsActions
            List(store.state.export.sorted(), id: \.self) { ip in
                VStack(alignment: .leading) {
                    Text(ip).font(.system(.body, design: .monospaced))
                    Text(owners(of: ip)).font(.caption).foregroundStyle(.secondary)
                }.textSelection(.enabled)
            }
            HStack { Text("Адресов: \(store.state.export.count)").foregroundStyle(.secondary); Spacer(); Button("Открыть папку автоматической выгрузки") { NSWorkspace.shared.open(store.folder) } }
        }
    }

    private func owners(of ip: String) -> String {
        let catalogMode = CatalogRouteMode(rawValue: store.state.mode.rawValue)!
        var result = catalogServices
            .filter { selectedCatalogIDs.contains($0.id) && catalogRoutes(for: $0, mode: store.state.mode).contains(ip) }
            .map(\.name)
        if store.state.selectedUnassignedModes.contains(catalogMode), unassignedRoutes.contains(ip) { result.append("Остальные сети источника") }
        if store.state.manualEnabled && store.state.manual.contains(where: { $0.address == ip }) { result.append("Мои IP") }
        return result.isEmpty ? "Адрес выбран текущим режимом" : result.joined(separator: ", ")
    }

    private var allowedIPsActions: some View {
        GroupBox("AmneziaWG: маршруты через VPN") {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = store.allowedIPsSummary {
                    Text("AllowedIPs: \(summary.routeCount) маршрутов · \(summary.byteCount) байт")
                    Text("Эти маршруты пойдут через VPN выбранного peer. Для режима «мимо VPN» используйте JSON-список исключений AmneziaVPN или действие «Пустить выбранное мимо VPN» при обогащении .conf.")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.state.mode == .full {
                        Label("Полный список может быть слишком большим для Android или iOS. Для телефона рекомендуются Lite или выбранные сервисы.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text("Выберите хотя бы один сервис, «Остальные сети источника» или «Мои IP», чтобы сформировать AllowedIPs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button { requestAllowedIPsAction(.copy) } label: { Label("Копировать AllowedIPs", systemImage: "doc.on.doc") }
                    Button { requestAllowedIPsAction(.save) } label: { Label("Сохранить строку", systemImage: "square.and.arrow.down") }
                    Button { requestAllowedIPsAction(.configure) } label: { Label("Создать конфигурацию AmneziaWG", systemImage: "gearshape.2") }
                }.disabled(!store.exportReady)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func requestAllowedIPsAction(_ action: AllowedIPsAction) {
        guard store.allowedIPsSummary != nil else {
            store.copyAllowedIPs()
            return
        }
        if store.state.mode == .full {
            ui.pendingAllowedIPsAction = action
            ui.showFullRouteWarning = true
        } else {
            performAllowedIPsAction(action)
        }
    }

    private func performAllowedIPsAction(_ action: AllowedIPsAction) {
        switch action {
        case .copy:
            store.copyAllowedIPs()
        case .save:
            store.saveAllowedIPs()
        case .configure:
            let prepared = store.chooseConfigurationInputs()
            ui.configurationInputs = prepared.inputs
            ui.configurationResults = prepared.issues
            ui.configurationOutputFolder = nil
            if !prepared.inputs.isEmpty { ui.showConfigurationSheet = true }
        }
    }

    private var modePicker: some View {
        Picker("Режим выгрузки", selection: Binding(get: { store.state.mode }, set: { store.setMode($0) })) {
            ForEach([ExportMode.targeted, .lite, .full], id: \.self) { mode in Text(mode.title).tag(mode) }
        }.pickerStyle(.segmented).disabled(store.busy)
    }

    private var settings: some View {
        Form {
            Section("Режим выгрузки") {
                modePicker
                Text(store.state.mode.detail).font(.caption).foregroundStyle(.secondary)
                Text("Источник: \(activeSourceURL)").font(.caption).textSelection(.enabled)
                Text("Выбор категорий применяется только к точечному обходу. Lite предназначен для Android/iOS, полный список — для десктопа.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Профили выбора") { profilesView }
            Section("Значок приложения") {
                Toggle("Показывать в Dock", isOn: Binding(get: { store.state.dockIconVisible }, set: { store.setDockIconVisible($0) }))
                Toggle("Показывать значок в строке меню", isOn: Binding(get: { store.state.menuBarIconVisible }, set: { store.setMenuBarIconVisible($0) }))
                Text("Значок в строке меню сигнализирует (значок колокольчика), если после обновления появились или удалились адреса. Нельзя скрыть оба значка одновременно — иначе к IPList будет не добраться.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Расписание") {
                Toggle("Обновлять автоматически", isOn: $store.state.automatic).onChange(of: store.state.automatic) { _ in store.persist() }
                Stepper("Каждые \(store.state.intervalHours) ч.", value: $store.state.intervalHours, in: 1...720).onChange(of: store.state.intervalHours) { _ in store.persist() }
                Text("Расписание работает, пока IPList запущен, в том числе при закрытом окне.").font(.caption).foregroundStyle(.secondary)
                if let date = store.state.lastCheck(for: store.state.mode) { Text("Последняя успешная проверка: \(date.formatted())") }
                Button("Разрешить уведомления macOS") { Task { do { let ok = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]); store.message = ok ? "Уведомления разрешены" : "Уведомления выключены в настройках macOS" } catch { store.error = error.localizedDescription } } }
            }
            Section("Источники HTTPS") {
                TextField("Точечный JSON с IP", text: $store.state.sourceURL)
                TextField("Lite JSON с IP", text: $store.state.liteSourceURL)
                TextField("Полный JSON с IP", text: $store.state.fullSourceURL)
                TextField("База категорий (URL с / в конце)", text: $store.state.categoryBaseURL)
                Button("Сохранить источники") { store.persist() }
                Link("lib4u/amnezia-tunneling-ru", destination: URL(string: "https://github.com/lib4u/amnezia-tunneling-ru")!)
                Link("Категории v2fly/domain-list-community", destination: URL(string: "https://github.com/v2fly/domain-list-community")!)
            }
            Section("Проверка источников") { sourceChecksView }
        }.formStyle(.grouped)
    }

    @ViewBuilder private var profilesView: some View {
        HStack {
            TextField("Название нового профиля", text: $ui.profileName)
            Button("Сохранить текущий") { let name = ui.profileName.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }; store.saveProfile(name: name); ui.profileName = "" }
        }
        if store.state.profiles.isEmpty { Text("Профилей пока нет.").foregroundStyle(.secondary) }
        ForEach(store.state.profiles, id: \.id) { profile in
            HStack {
                Image(systemName: store.selectedProfileID == profile.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(store.selectedProfileID == profile.id ? Color.teal : Color.secondary)
                Text(profile.name)
                Spacer()
                Button("Применить") { store.applyProfile(profile.id) }.disabled(store.busy)
                Button("Обновить") { store.updateProfile(profile.id) }.disabled(store.busy)
                Button(role: .destructive) { store.deleteProfile(profile.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).disabled(store.busy)
            }
        }
    }

    @ViewBuilder private var sourceChecksView: some View {
        Button { Task { await store.testSources() } } label: { Label(store.testingSources ? "Проверяю источники…" : "Проверить источники", systemImage: "network.badge.shield.half.filled") }.disabled(store.busy || store.testingSources)
        let checks = store.sourceChecks
        if checks.isEmpty { Text("Проверка покажет доступность, HTTP-код, длительность и ошибку для каждого источника.").font(.caption).foregroundStyle(.secondary) }
        SourceCheckRows(checks: checks)
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Выберите адреса для «Моих IP»").font(.title2.bold())
            Text("Адреса не включаются автоматически.")
            List(ui.importRows, id: \.self) { ip in Toggle(ip, isOn: Binding(get: { ui.importSelection.contains(ip) }, set: { if $0 { ui.importSelection.insert(ip) } else { ui.importSelection.remove(ip) } })).font(.system(.body, design: .monospaced)) }
            HStack { Button("Отмена") { ui.showImport = false }; Spacer(); Text("Выбрано: \(ui.importSelection.count)"); Button("Добавить выбранные") { store.addManual(ui.importSelection.joined(separator: "\n")); ui.showImport = false }.disabled(ui.importSelection.isEmpty) }
        }.padding(24).frame(width: 620, height: 520)
    }

    private struct ConfigurationPreview {
        let currentRouteCount: Int
        let finalRouteCount: Int?
        let validationMessage: String

        var isValid: Bool { finalRouteCount != nil }
    }

    private func configurationPreview(for input: ConfigurationInput) -> ConfigurationPreview {
        let currentRouteCount = allowedIPsRouteCount(in: input.source)
        guard !store.state.export.isEmpty else {
            return ConfigurationPreview(currentRouteCount: currentRouteCount, finalRouteCount: nil,
                                        validationMessage: "Выберите хотя бы один маршрут для AllowedIPs.")
        }
        do {
            let rendered = try input.document.render(
                peer: input.peer,
                operation: ui.configurationOperation.operation,
                routes: store.state.export.sorted(),
                preserveIPv6: ui.preserveConfigurationIPv6
            )
            _ = try AmneziaWGDocument.parse(rendered)
            return ConfigurationPreview(currentRouteCount: currentRouteCount,
                                        finalRouteCount: allowedIPsRouteCount(in: rendered),
                                        validationMessage: "Структура и пересечения с другими peer проверены.")
        } catch {
            return ConfigurationPreview(currentRouteCount: currentRouteCount, finalRouteCount: nil,
                                        validationMessage: error.localizedDescription)
        }
    }

    private func peerBinding(for inputID: UUID) -> Binding<Int> {
        Binding(
            get: { ui.configurationInputs.first(where: { $0.id == inputID })?.peer ?? 0 },
            set: { peer in
                guard let index = ui.configurationInputs.firstIndex(where: { $0.id == inputID }) else { return }
                ui.configurationInputs[index].peer = peer
            }
        )
    }

    private var configurationCanSave: Bool {
        !ui.configurationInputs.isEmpty && ui.configurationOutputFolder != nil &&
            ui.configurationInputs.allSatisfy { configurationPreview(for: $0).isValid }
    }

    private var configurationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Создать конфигурацию AmneziaWG").font(.title2.bold())
            Text("Исходные .conf не изменяются. Для каждого файла будет создан отдельный новый файл с суффиксом -iplist.")
                .foregroundStyle(.secondary)
            Picker("Что сделать с маршрутами", selection: $ui.configurationOperation) {
                ForEach(ConfigurationOperation.allCases) { operation in Text(operation.title).tag(operation) }
            }
            Text(operationExplanation).font(.caption).foregroundStyle(.secondary)
            Toggle("Сохранить существующие IPv6 при замене", isOn: $ui.preserveConfigurationIPv6)
                .disabled(ui.configurationOperation != .replace)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(ui.configurationInputs) { input in
                        let preview = configurationPreview(for: input)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(input.url.lastPathComponent).font(.headline)
                            if configurationNeedsPeerChoice(input.document) {
                                Picker("Peer", selection: peerBinding(for: input.id)) {
                                    ForEach(input.document.peers, id: \.index) { peer in Text(peer.displayName).tag(peer.index) }
                                }
                            }
                            let recommendation = recommendedConfigurationOperation(existingRoutes: allowedIPsRouteStrings(in: input.source))
                            Text(recommendation == .add
                                 ? "Совет: в этой частичной IPv4-конфигурации обычно достаточно добавить маршруты."
                                 : "Совет: 0.0.0.0/0 уже покрывает IPv4; выберите вычитание для «мимо VPN» или замену.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let finalRouteCount = preview.finalRouteCount {
                                Text("Маршрутов в конфигурации: было \(preview.currentRouteCount), станет \(finalRouteCount).")
                                Text(preview.validationMessage).font(.caption).foregroundStyle(.green)
                            } else {
                                Label(preview.validationMessage, systemImage: "xmark.octagon.fill")
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            HStack {
                Button("Выбрать папку") { ui.configurationOutputFolder = store.chooseConfigurationOutputFolder() }
                Text(ui.configurationOutputFolder?.path ?? "Папка не выбрана")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            if !ui.configurationResults.isEmpty {
                ForEach(ui.configurationResults) { result in
                    Label("\(result.name): \(result.message)", systemImage: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption).foregroundStyle(result.success ? .green : .red)
                }
            }
            HStack {
                Button("Закрыть") {
                    ui.configurationInputs = []
                    ui.configurationOutputFolder = nil
                    ui.showConfigurationSheet = false
                }
                Spacer()
                Button("Создать новые файлы") {
                    guard let outputFolder = ui.configurationOutputFolder else { return }
                    ui.configurationResults = store.saveEnrichedConfigurations(
                        ui.configurationInputs,
                        operation: ui.configurationOperation,
                        preserveIPv6: ui.preserveConfigurationIPv6,
                        to: outputFolder
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!configurationCanSave)
            }
        }
        .padding(24)
        .frame(width: 760, height: 660)
    }

    private var operationExplanation: String {
        switch ui.configurationOperation {
        case .add:
            return "Добавляет выбранные маршруты к AllowedIPs выбранного peer. При 0.0.0.0/0 новые IPv4 уже покрыты."
        case .replace:
            return "Записывает только выбранные IPv4; существующие IPv6 можно оставить отдельной галочкой."
        case .bypass:
            return "Вычитает выбранные IPv4 из текущих AllowedIPs. Эти адреса будут идти мимо VPN; это действие выбрано по умолчанию."
        }
    }

    private var activeSourceURL: String {
        switch store.state.mode {
        case .targeted: return store.state.sourceURL
        case .lite: return store.state.liteSourceURL
        case .full: return store.state.fullSourceURL
        }
    }
}

private struct SourceCheckRows: View {
    let checks: [SourceCheck]

    var body: some View {
        ForEach(checks, id: \.id) { check in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: check.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(check.success ? Color.green : Color.red)
                    Text(check.name).font(.headline)
                    Spacer()
                    Text(check.statusCode.map(String.init) ?? "—").font(.caption.monospaced())
                }
                Text(check.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Text(String(format: "%.0f мс", check.duration * 1000))
                    if let count = check.addressCount { Text("· \(count) адресов") }
                    if !check.message.isEmpty { Text("· \(check.message)").foregroundStyle(check.success ? Color.secondary : Color.red) }
                }.font(.caption)
            }.padding(.vertical, 4)
        }
    }
}
