import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers

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
    var exportReady: Bool {
        switch state.mode {
        case .targeted: return !state.services.isEmpty
        case .lite: return !state.liteAddresses.isEmpty
        case .full: return !state.fullAddresses.isEmpty
        }
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
            }
        } catch { self.error = "Не удалось прочитать сохранённые данные: \(error.localizedDescription)" }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkSchedule() } }
        applyIconVisibility()
        Task { checkSchedule() }
    }
    func checkSchedule() {
        if state.automatic && !busy && !testingSources && Date() >= nextRetry && Date().timeIntervalSince(state.lastCheck(for: state.mode) ?? .distantPast) >= Double(state.intervalHours) * 3600 { Task { await refresh() } }
    }
    func persist() {
        do {
            try JSONEncoder().encode(state).write(to: folder.appendingPathComponent("state.json"), options: .atomic)
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
        for id in ids { if enabled { state.selected.insert(id) } else { state.selected.remove(id) } }
        state.selectionInitialized = true
        state.selectAllByDefault = !state.services.isEmpty && Set(state.services.map(\.id)).isSubset(of: state.selected)
        selectedProfileID = nil
        record(before: before, reason: "Изменён выбор сервисов"); persist()
    }
    func selectAll(_ enabled: Bool) {
        let before = state.export
        state.selected = enabled ? Set(state.services.map(\.id)) : []
        state.selectAllByDefault = enabled; state.selectionInitialized = true; selectedProfileID = nil
        record(before: before, reason: enabled ? "Выбраны все категории" : "Снят выбор всех категорий"); persist()
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
        state.profiles.append(SelectionProfile(name: clean, selected: state.selected, mode: state.mode, manualEnabled: state.manualEnabled, selectAllByDefault: state.selectAllByDefault))
        selectedProfileID = state.profiles.last?.id; persist(); message = "Профиль «\(clean)» сохранён."
    }
    func updateProfile(_ id: UUID) {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
        state.profiles[index].selected = state.selected; state.profiles[index].mode = state.mode
        state.profiles[index].manualEnabled = state.manualEnabled; state.profiles[index].selectAllByDefault = state.selectAllByDefault
        selectedProfileID = id; persist(); message = "Профиль обновлён."
    }
    func applyProfile(_ id: UUID) {
        guard !busy, let profile = state.profiles.first(where: { $0.id == id }) else { return }
        let before = state.export
        state.selected = profile.selected.intersection(Set(state.services.map(\.id)))
        state.mode = profile.mode; state.manualEnabled = profile.manualEnabled
        state.selectAllByDefault = profile.selectAllByDefault; state.selectionInitialized = true
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
        let mode = state.mode
        message = "Загружаю «\(mode.title)»…"
        do {
            let loader = CatalogLoader()
            let before = state.export
            let oldAll: Set<String>
            let newAll: Set<String>
            let first = state.lastCheck(for: mode) == nil
            switch mode {
            case .targeted:
                let services = try await loader.load(source: state.sourceURL, base: state.categoryBaseURL) { [weak self] status in Task { @MainActor in self?.message = status } }
                oldAll = Set(state.services.flatMap(\.addresses)); newAll = Set(services.flatMap(\.addresses))
                state.applyCatalog(services)
            case .lite:
                let addresses = try await loader.loadRanges(mode: mode, source: state.liteSourceURL)
                oldAll = Set(state.liteAddresses); newAll = Set(addresses); state.liteAddresses = newAll
            case .full:
                let addresses = try await loader.loadRanges(mode: mode, source: state.fullSourceURL)
                oldAll = Set(state.fullAddresses); newAll = Set(addresses); state.fullAddresses = newAll
            }
            state.markChecked(mode); nextRetry = .distantPast
            record(before: before, reason: first ? "Первая загрузка: \(mode.title)" : "Обновление: \(mode.title)")
            if !first {
                let added = newAll.subtracting(oldAll).sorted(), removed = oldAll.subtracting(newAll).sorted()
                if !added.isEmpty || !removed.isEmpty {
                    state.changes.insert(Change(added: added, removed: removed, reason: "Источник: \(mode.title)"), at: 0)
                    state.changes = Array(state.changes.prefix(100))
                    state.hasUnseenChanges = true
                }
                if !added.isEmpty || !removed.isEmpty || before != state.export {
                    let content = UNMutableNotificationContent(); content.title = "IPList: список изменился"
                    content.body = "Источник: +\(added.count), −\(removed.count). Выгрузка: +\(state.export.subtracting(before).count), −\(before.subtracting(state.export).count)."
                    try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
                }
            }
            persist(); message = "Проверка завершена: \(mode.title), \(newAll.count) IPv4 / диапазонов. В выгрузке: \(state.export.count)."
        } catch {
            nextRetry = Date().addingTimeInterval(15 * 60)
            self.error = error.localizedDescription
            message = "Обновление не выполнено. Предыдущие данные сохранены. Проверьте источники в настройках."
        }
    }
    func exportFile() {
        guard exportReady else { error = "Сначала загрузите данные выбранного режима кнопкой «Проверить сейчас»."; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "amnezia-\(state.mode.rawValue).json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try exportData(state.export).write(to: url, options: .atomic); message = "Экспортировано \(state.export.count) адресов в \(url.lastPathComponent)." } catch { self.error = error.localizedDescription }
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
        .sheet(isPresented: $ui.showImport) { importSheet }
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
            if store.state.mode != .targeted {
                Label("Сейчас выбран режим «\(store.state.mode.title)». Выбор категорий влияет только на «Точечный обход».", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Поиск сервиса, домена или IP", text: $ui.search).textFieldStyle(.roundedBorder)
                Toggle("Все категории", isOn: Binding(get: { allSelected }, set: { store.selectAll($0) }))
                    .toggleStyle(.checkbox).frame(width: 155).disabled(store.busy)
                Text("\(selectedCount)/\(store.state.services.count)").foregroundStyle(.secondary).font(.caption)
            }
            if store.state.services.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "network").font(.system(size: 56)).foregroundStyle(.teal)
                    Text("Начните с обновления каталога").font(.title2)
                    Text("После загрузки все категории будут выбраны автоматически.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(categories, id: \.self) { category in
                        let all = services(in: category)
                        let visible = matching(all)
                        if !visible.isEmpty {
                            DisclosureGroup(isExpanded: Binding(get: { ui.expandedCategories.contains(category) }, set: { value in if value { ui.expandedCategories.insert(category) } else { ui.expandedCategories.remove(category) } })) {
                                ForEach(visible) { service in serviceRow(service) }
                            } label: {
                                categoryHeader(category, all: all)
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: ui.search) { _ in
            if ui.search.isEmpty { ui.expandedCategories.removeAll() }
            else { ui.expandedCategories = Set(categories.filter { !matching(services(in: $0)).isEmpty }) }
        }
    }

    private func categoryHeader(_ category: String, all: [Service]) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { all.allSatisfy { store.state.selected.contains($0.id) } }, set: { store.select(all.map(\.id), enabled: $0) })) { Label(category, systemImage: categoryIcon(category)).font(.headline) }.toggleStyle(.checkbox).disabled(store.busy)
            Spacer()
            Text("\(all.filter { store.state.selected.contains($0.id) }.count)/\(all.count)").font(.caption).foregroundStyle(.secondary)
            Button("Все") { store.select(all.map(\.id), enabled: true) }.buttonStyle(.borderless).font(.caption).disabled(store.busy)
            Button("Снять") { store.select(all.map(\.id), enabled: false) }.buttonStyle(.borderless).font(.caption).disabled(store.busy)
        }
    }

    private func serviceRow(_ service: Service) -> some View {
        DisclosureGroup {
            Text(service.domains.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(service.addresses.isEmpty ? "Нет IPv4 в источнике; в выгрузку не попадёт" : service.addresses.joined(separator: ", ")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        } label: {
            Toggle(isOn: Binding(get: { store.state.selected.contains(service.id) }, set: { store.select([service.id], enabled: $0) })) {
                HStack { Text(service.name); Spacer(); Text("\(service.addresses.count) IP").foregroundStyle(.secondary).font(.caption) }
            }.toggleStyle(.checkbox).disabled(store.busy)
        }.padding(.vertical, 3)
    }

    private var categories: [String] { Array(Set(store.state.services.map(\.category))).sorted() }
    private func services(in category: String) -> [Service] { store.state.services.filter { $0.category == category } }
    private func matching(_ services: [Service]) -> [Service] {
        guard !ui.search.isEmpty else { return services }
        return services.filter { ($0.name + " " + $0.domains.joined(separator: " ") + " " + $0.addresses.joined(separator: " ")).localizedCaseInsensitiveContains(ui.search) }
    }
    private var selectedCount: Int { store.state.services.filter { store.state.selected.contains($0.id) }.count }
    private var allSelected: Bool { !store.state.services.isEmpty && selectedCount == store.state.services.count }

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
            if store.state.mode == .targeted {
                Text("В режиме «Точечный обход» используются выбранные категории и сервисы.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("В этом режиме выгружается полный upstream-список; выбор категорий каталога на него не влияет.").font(.caption).foregroundStyle(.secondary)
            }
            List(store.state.export.sorted(), id: \.self) { ip in
                VStack(alignment: .leading) {
                    Text(ip).font(.system(.body, design: .monospaced))
                    if store.state.mode == .targeted { Text(owners(of: ip)).font(.caption).foregroundStyle(.secondary) }
                }.textSelection(.enabled)
            }
            HStack { Text("Адресов: \(store.state.export.count)").foregroundStyle(.secondary); Spacer(); Button("Открыть папку автоматической выгрузки") { NSWorkspace.shared.open(store.folder) } }
        }
    }

    private func owners(of ip: String) -> String {
        (store.state.services.filter { store.state.selected.contains($0.id) && $0.addresses.contains(ip) }.map(\.name) + (store.state.manualEnabled && store.state.manual.contains { $0.address == ip } ? ["Мои IP"] : [])).joined(separator: ", ")
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
