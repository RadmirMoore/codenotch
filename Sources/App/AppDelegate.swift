import AppKit
import SwiftUI
import Combine

@MainActor final class WidgetSettings: ObservableObject {
    @Published var edge: NotchEdge { didSet { save() } }
    @Published var visibility: NotchVisibility { didSet { save() } }
    @Published var surface: NotchSurfaceStyle { didSet { save() } }
    @Published var scope: NotchScreenScope { didSet { save() } }
    @Published var scale: Double { didSet { save() } }
    @Published var resetFormat: ResetTimeFormat { didSet { save() } }
    @Published var offset: Double { didSet { save() } }
    private let defaults = UserDefaults.standard
    init() {
        edge = NotchEdge(rawValue: defaults.string(forKey: "widget.edge") ?? "right") ?? .right
        visibility = NotchVisibility(rawValue: defaults.string(forKey: "widget.visibility") ?? "onHover") ?? .onHover
        surface = NotchSurfaceStyle(rawValue: defaults.string(forKey: "widget.surface") ?? "glass") ?? .glass
        scope = NotchScreenScope(rawValue: defaults.string(forKey: "widget.scope") ?? "mainDisplay") ?? .mainDisplay
        resetFormat = ResetTimeFormat(rawValue: defaults.string(forKey: "widget.resetFormat") ?? "remaining") ?? .remaining
        scale = defaults.object(forKey: "widget.scale") == nil ? 1 : min(1.6, max(0.8, defaults.double(forKey: "widget.scale")))
        offset = defaults.double(forKey: "widget.offset")
        defaults.set("ru", forKey: L10n.languageDefaultsKey)
    }
    private func save() {
        defaults.set(edge.rawValue, forKey: "widget.edge")
        defaults.set(visibility.rawValue, forKey: "widget.visibility")
        defaults.set(surface.rawValue, forKey: "widget.surface")
        defaults.set(scope.rawValue, forKey: "widget.scope")
        defaults.set(resetFormat.rawValue, forKey: "widget.resetFormat")
        defaults.set(scale, forKey: "widget.scale")
        defaults.set(offset, forKey: "widget.offset")
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: CodexMonitor!
    private var settings: WidgetSettings!
    private var fleet: NotchFleet!
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Runtime.isUnderTest else { return }
        settings = WidgetSettings()
        monitor = CodexMonitor()
        fleet = NotchFleet(scope: settings.scope, edge: settings.edge)
        applySettings()
        fleet.apply(weeklyRing: .outside)
        fleet.apply(weeklyReading: true)
        fleet.onOpenSettings = { [weak self] in self?.openSettings() }
        fleet.onRefresh = { [weak self] in self?.monitor.refresh() }
        fleet.onRefreshProvider = { [weak self] _ in self?.monitor.refresh() }
        fleet.onMoveToEdge = { [weak self] edge, offset in
            self?.settings.edge = edge
            self?.settings.offset = Double(offset ?? 0)
        }
        fleet.onReposition = { [weak self] offset in self?.settings.offset = Double(offset) }
        monitor.$snapshot.sink { [weak self] in self?.fleet.setSnapshots([$0]); self?.updateStatus($0) }.store(in: &cancellables)
        monitor.$refreshing.sink { [weak self] in self?.fleet.setRefreshing($0 ? ["codex"] : []) }.store(in: &cancellables)
        settings.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.applySettings() }.store(in: &cancellables)
        setupMenu()
        fleet.show()
        monitor.start()
        openSettings()
    }
    private func applySettings() {
        fleet.apply(edge: settings.edge)
        fleet.apply(settings.visibility)
        fleet.apply(scope: settings.scope)
        fleet.apply(surfaceStyle: settings.surface)
        fleet.apply(scale: settings.scale)
        fleet.apply(alongOffset: settings.offset)
        fleet.apply(resetTimeFormat: settings.resetFormat)
    }
    private func setupMenu() {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Codenotch", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self; appMenu.addItem(settingsItem)
        let refreshItem = NSMenuItem(title: "Обновить лимиты", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self; appMenu.addItem(refreshItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Завершить Codenotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Codex —"
        status.menu = appMenu.copy() as? NSMenu
        statusItem = status
    }
    private func updateStatus(_ snapshot: ProviderSnapshot) {
        statusItem?.button?.title = "Codex \(snapshot.headlineText)\(snapshot.status.isStale ? " · !" : "")"
        statusItem?.button?.toolTip = "Остаток лимита Codex. Нажмите для настроек."
    }
    @objc private func refresh() { monitor.refresh() }
    @objc func openSettings() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Codenotch — лимиты Codex"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: CodexSettingsView(monitor: monitor, settings: settings))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct CodexSettingsView: View {
    @ObservedObject var monitor: CodexMonitor
    @ObservedObject var settings: WidgetSettings
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Остаток лимита Codex").font(.title2.bold())
                Text("Под кольцом — оставшийся процент. Если сервер сообщает оба окна, показаны короткое и недельное. При наведении видны лимиты и время сброса.")
                    .foregroundStyle(.secondary)
                ForEach(monitor.snapshot.windows) { limit in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(limit.label).font(.headline)
                            if let reset = limit.resetsAt {
                                Text("Сброс: \(reset.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                                TimelineView(.periodic(from: .now, by: 30)) { context in
                                    Text(ResetCopy.text(for: reset, now: context.date, format: .remaining)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        if let used = limit.usedFraction { Text("\(Percent.text(for: max(0, 1 - used)))% осталось").monospacedDigit() }
                    }
                }
                Text(monitor.message).font(.callout).foregroundStyle(monitor.snapshot.status.isStale ? .orange : .secondary)
                if let updated = monitor.updatedAt { Text("Последнее успешное чтение: \(updated.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button(monitor.connected ? "Выбрать auth.json заново…" : "Подключить Codex…") { monitor.chooseFile() }
                    Button("Обновить") { monitor.refresh() }.disabled(!monitor.connected || monitor.refreshing)
                    if monitor.connected { Button("Отключить") { monitor.disconnect() } }
                }
                Divider()
                Picker("Край экрана", selection: $settings.edge) {
                    Text("Справа").tag(NotchEdge.right); Text("Слева").tag(NotchEdge.left)
                    Text("Сверху").tag(NotchEdge.top); Text("Снизу").tag(NotchEdge.bottom)
                }
                Picker("Видимость", selection: $settings.visibility) { ForEach(NotchVisibility.allCases) { Text($0.title).tag($0) } }
                Picker("Экраны", selection: $settings.scope) { ForEach(NotchScreenScope.allCases) { Text($0.title).tag($0) } }
                Picker("Оформление", selection: $settings.surface) { ForEach(NotchSurfaceStyle.allCases) { Text($0.title).tag($0) } }
                Picker("Время сброса", selection: $settings.resetFormat) { ForEach(ResetTimeFormat.allCases) { Text($0.title).tag($0) } }
                HStack { Text("Размер"); Slider(value: $settings.scale, in: 0.8...1.6) }
                Text("Для переноса раскройте виджет и потяните за ручку перемещения к нужному краю. Option (⌥) + перетаскивание — положение вдоль края.").font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Только Codex · чтение auth.json · запросы только к chatgpt.com · без обновлений приложения, телеметрии и доступа к переписке.").font(.caption).foregroundStyle(.secondary)
                Button("Завершить Codenotch") { NSApp.terminate(nil) }
            }.padding(24)
        }.frame(width: 580, height: 650)
    }
}
