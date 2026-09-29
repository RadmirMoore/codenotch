import AppKit
import SwiftUI
import TokenCounter

@main
struct CodenotchLocalApp: App {
    @StateObject private var model = CounterModel()

    var body: some Scene {
        MenuBarExtra {
            CounterView(model: model)
        } label: {
            Text(model.menuTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class CounterModel: ObservableObject {
    @Published private(set) var snapshot = CounterSnapshot()
    @Published private(set) var folders: [URL] = []
    @Published private(set) var scanning = false
    @Published private(set) var message: String?
    @Published private(set) var refreshed: Date?
    private let scanner = LogScanner()
    private var timer: Timer?
    private var selecting = false
    private let bookmarkKey = "selectedReadOnlyLogFolders.v1"

    var menuTitle: String {
        guard !folders.isEmpty else { return "Codex —" }
        guard refreshed != nil else { return "Codex …" }
        return "Codex \(Self.compact(snapshot.today.total))\(snapshot.catchingUp ? "…" : "")"
    }

    init() {
        // Only bookmarks created by a previous explicit folder selection.
        // There is deliberately no search of ~/.codex, Keychain or other apps.
        let bookmarks = UserDefaults.standard.array(forKey: bookmarkKey) as? [Data] ?? []
        var renewed: [Data] = []
        for bookmark in bookmarks {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: bookmark,
                                  options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else {
                    message = "Выбери папку журналов повторно: разрешение недоступно."
                    continue
                }
                guard Self.allowedFolder(url) else {
                    url.stopAccessingSecurityScopedResource()
                    message = "Выбери папку sessions или archived_sessions повторно."
                    continue
                }
                if folders.contains(url) { url.stopAccessingSecurityScopedResource(); continue }
                do {
                    let saved = stale ? try Self.bookmark(url) : bookmark
                    folders.append(url); renewed.append(saved)
                } catch {
                    url.stopAccessingSecurityScopedResource()
                    message = "Не удалось восстановить доступ. Выбери папку повторно."
                }
            } catch { message = "Не удалось восстановить доступ. Выбери папку повторно." }
        }
        UserDefaults.standard.set(renewed, forKey: bookmarkKey)
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    private static func allowedFolder(_ url: URL) -> Bool {
        guard url.isFileURL, ["sessions", "archived_sessions"].contains(url.lastPathComponent),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func chooseFolders() {
        guard !scanning, !selecting else { return }
        selecting = true
        let panel = NSOpenPanel()
        panel.title = "Журналы Codex"
        panel.message = "Нажми ⌘⇧G и введи ~/.codex/sessions. Для архива можно отдельно добавить ~/.codex/archived_sessions."
        panel.prompt = "Разрешить чтение"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            message = nil
            var bookmarks = UserDefaults.standard.array(forKey: bookmarkKey) as? [Data] ?? []
            for url in panel.urls {
                guard Self.allowedFolder(url) else {
                    message = "Выбери именно sessions или archived_sessions, а не всю папку .codex."
                    continue
                }
                guard !folders.contains(url) else { continue }
                guard url.startAccessingSecurityScopedResource() else {
                    message = "macOS не предоставила доступ к выбранной папке."
                    continue
                }
                do {
                    bookmarks.append(try Self.bookmark(url))
                    folders.append(url)
                } catch {
                    url.stopAccessingSecurityScopedResource()
                    message = "Не удалось сохранить разрешение на чтение."
                }
            }
            UserDefaults.standard.set(bookmarks, forKey: bookmarkKey)
        }
        selecting = false
        refresh()
    }

    func refresh() {
        guard !scanning, !selecting, !folders.isEmpty else { return }
        scanning = true
        let selected = folders
        Task {
            let result = await scanner.scan(roots: selected)
            snapshot = result
            refreshed = Date()
            scanning = false
            // Initial large histories are read in bounded chunks off the UI actor.
            if result.catchingUp {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                refresh()
            }
        }
    }

    func forgetFolders() {
        guard !scanning, !selecting else { return }
        scanning = true
        Task {
            await scanner.clear()
            for url in folders { url.stopAccessingSecurityScopedResource() }
            folders.removeAll()
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            snapshot = CounterSnapshot(); refreshed = nil; message = nil
            scanning = false
        }
    }

    static func compact(_ count: Int64) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 10_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return count.formatted()
    }
}

private struct CounterView: View {
    @ObservedObject var model: CounterModel
    @State private var period = 0

    private var tokens: Tokens {
        switch period {
        case 1: return model.snapshot.week
        case 2: return model.snapshot.all
        default: return model.snapshot.today
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "lock.shield")
                Text("Codex · локальные токены").font(.headline)
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
            }
            if model.folders.isEmpty {
                Text("Добавь папку журналов Codex, чтобы начать подсчёт.")
                Text("⌘⇧G в диалоге выбора → ~/.codex/sessions")
                    .font(.caption).textSelection(.enabled)
            } else {
                Picker("Период", selection: $period) {
                    Text("Сегодня").tag(0)
                    Text("7 дней").tag(1)
                    Text("Всё время").tag(2)
                }.pickerStyle(.segmented)
                Text(tokens.total.formatted()).font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit().textSelection(.enabled)
                VStack(spacing: 6) {
                    row("Входящие", tokens.input)
                    row("Из них из кэша", tokens.cached)
                    row("Исходящие", tokens.output)
                    row("Из них рассуждения", tokens.reasoning)
                }
                Text("Всего = входящие + исходящие. Кэш и рассуждения уже входят в эти числа.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.snapshot.catchingUp {
                    Text("Читаю историю… Показаны промежуточные суммы.").font(.caption)
                } else if model.snapshot.events == 0 {
                    Text("В выбранных журналах пока нет поддерживаемых записей token_count.")
                        .font(.caption)
                }
                Text("Файлов: \(model.snapshot.files) · записей использования: \(model.snapshot.events)")
                    .font(.caption).foregroundStyle(.secondary)
                if let time = model.refreshed {
                    Text("Проверено: \(time.formatted(date: .omitted, time: .standard)) · каждые 15 секунд")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.snapshot.skipped > 0 || model.snapshot.resets > 0 {
                    Text("Есть пропуски или сбросы счётчиков (\(model.snapshot.skipped) / \(model.snapshot.resets)). Суммы могут быть неполными.")
                        .font(.caption).foregroundStyle(.orange)
                }
                DisclosureGroup("Доступные папки") {
                    ForEach(model.folders, id: \.self) { folder in
                        Text(folder.path).font(.caption).textSelection(.enabled)
                    }
                }.font(.caption)
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.orange) }
            Divider()
            Text("Без интернета, ключей входа и обновлений. Только выбранные журналы; это не лимит подписки и не счёт за API.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Добавить папку…", action: model.chooseFolders).disabled(model.scanning)
                Button("Обновить", action: model.refresh).disabled(model.scanning || model.folders.isEmpty)
            }
            HStack {
                Button("Забыть папки", action: model.forgetFolders).disabled(model.scanning || model.folders.isEmpty)
                Spacer()
                Button("Выход") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    private func row(_ label: String, _ value: Int64) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.formatted()).monospacedDigit().textSelection(.enabled)
        }
    }
}
