import AppKit
import Combine
import CryptoKit

@MainActor final class CodexMonitor: ObservableObject {
    @Published private(set) var snapshot = CodexMonitor.placeholder
    @Published private(set) var message = "Выберите auth.json из папки .codex."
    @Published private(set) var updatedAt: Date?
    @Published private(set) var refreshing = false
    @Published private(set) var connected = false
    private let connection = CodexConnection()
    private var authURL: URL?
    private var scopedURL: URL?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var identity: String?
    private var lastAttempt = Date.distantPast
    private let bookmarkKey = "codex.selectedAuthFile.v2"
    static var placeholder: ProviderSnapshot {
        ProviderSnapshot(id: "codex", displayName: "Codex · осталось", glyph: .openai,
                         fidelity: .official, status: .needsAuth, windows: [])
    }
    init() {
        // Retire grants used by the old offline counter; never open its folders.
        UserDefaults.standard.removeObject(forKey: "selectedReadOnlyLogFolders.v1")
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else { throw CodexConnectionError.invalidCredential }
                scopedURL = url
                authURL = url
                connected = true
                if stale { try saveBookmark(url) }
            } catch { message = "Доступ к auth.json нужно выбрать заново." }
        }
    }
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Доступ к аккаунту Codex — только чтение"
        panel.message = "Выберите ~/.codex/auth.json. Токен будет отправляться только на chatgpt.com для чтения лимитов. Файл не изменяется."
        panel.prompt = "Подключить Codex"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            guard url.lastPathComponent == "auth.json" else { throw CodexConnectionError.invalidCredential }
            _ = try CodexCredential.read(url)
            try saveBookmark(url)
            disconnect(clearBookmark: false)
            authURL = url
            scopedURL = scoped ? url : nil
            connected = true
            refresh()
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            message = "Не удалось прочитать файл авторизации Codex. Выберите обычный auth.json с активным входом через ChatGPT."
        }
    }
    private func saveBookmark(_ url: URL) throws {
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }
    func disconnect(clearBookmark: Bool = true) {
        task?.cancel(); task = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil; authURL = nil; identity = nil
        updatedAt = nil; connected = false; refreshing = false
        snapshot = Self.placeholder
        lastAttempt = .distantPast
        message = "Аккаунт отключён. Вход в самом Codex сохранён."
        if clearBookmark { UserDefaults.standard.removeObject(forKey: bookmarkKey) }
    }
    func refresh() {
        guard !refreshing, let authURL, Date().timeIntervalSince(lastAttempt) >= 10 else { return }
        lastAttempt = Date()
        refreshing = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let credential = try CodexCredential.read(authURL)
                let nextIdentity = SHA256.hash(data: Data((credential.accountID + credential.accessToken).utf8)).map { String(format: "%02x", $0) }.joined()
                if identity != nextIdentity {
                    snapshot = Self.placeholder
                    updatedAt = nil
                    identity = nextIdentity
                }
                let fresh = try await connection.fetch(credential)
                guard !Task.isCancelled else { return }
                var next = fresh
                next.displayName = "Codex · осталось"
                snapshot = next
                updatedAt = Date()
                message = "Данные получены от Codex. Автообновление каждые 30 секунд."
            } catch {
                guard !Task.isCancelled else { return }
                if case UsageProviderError.needsAuth = error {
                    snapshot = Self.placeholder; updatedAt = nil
                    message = "Войдите заново в Codex, затем обновите данные здесь."
                } else {
                    if let updatedAt { snapshot.status = .stale(since: updatedAt) }
                    else { snapshot.status = .error("Нет актуальных данных") }
                    switch error {
                    case UsageProviderError.rateLimited(let delay):
                        message = "Сервер просит подождать. Следующая попытка после \(Date().addingTimeInterval(delay).formatted(date: .abbreviated, time: .standard))."
                    case CodexConnectionError.invalidCredential:
                        message = "Файл авторизации недоступен. Проверьте вход в Codex или выберите auth.json заново."
                    case UsageProviderError.badResponse(let status):
                        message = "Сервер вернул HTTP \(status). Последнее чтение помечено устаревшим."
                    default:
                        message = "Не удалось получить свежие лимиты. Повторная попытка через 30 секунд."
                    }
                }
            }
            refreshing = false
        }
    }
}
