import Foundation
import Darwin

/// No dynamic URLs, redirects, cookies, disk cache, credential storage or custom TLS trust.
enum CodexEndpoint: String, CaseIterable {
    case usage = "usage"
    case resetCredits = "rate-limit-reset-credits"
    var url: URL { URL(string: "https://chatgpt.com/backend-api/wham/" + rawValue)! }
    static func allows(_ url: URL) -> Bool { allCases.contains { $0.url == url } }
}

final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum CodexConnectionError: Error { case invalidCredential, oversizedResponse, redirect, invalidResponse }
struct CodexCredential {
    let accessToken: String
    let accountID: String
    static let maximumBytes = 1024 * 1024

    static func read(_ url: URL) throws -> Self {
        // Reopen the selected path each poll to follow Codex's atomic token rotations.
        // Never follow a substituted symlink or accept a device, FIFO or huge file.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CodexConnectionError.invalidCredential }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size > 0, st.st_size <= maximumBytes else { throw CodexConnectionError.invalidCredential }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CodexConnectionError.invalidCredential }
        return try decode(data)
    }
    static func decode(_ data: Data) throws -> Self {
        struct Auth: Decodable {
            struct Tokens: Decodable { let access_token: String; let account_id: String }
            let tokens: Tokens
        }
        guard data.count <= maximumBytes,
              let auth = try? JSONDecoder().decode(Auth.self, from: data),
              validHeader(auth.tokens.access_token), validHeader(auth.tokens.account_id)
        else { throw CodexConnectionError.invalidCredential }
        return Self(accessToken: auth.tokens.access_token, accountID: auth.tokens.account_id)
    }
    private static func validHeader(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count < 32768 && value.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }
}

actor CodexConnection {
    private let session: URLSession
    private let defaults: UserDefaults
    private static let backoffKey = "codex.retryAfter.v2"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
    }
    func fetch(_ credential: CodexCredential) async throws -> ProviderSnapshot {
        let deadline = defaults.double(forKey: Self.backoffKey)
        guard Date().timeIntervalSince1970 >= deadline else {
            throw UsageProviderError.rateLimited(retryAfter: deadline - Date().timeIntervalSince1970)
        }
        let data = try await request(.usage, credential)
        let windows = try CodexUsage.windows(from: data, includeExtras: true)
        // Supplemental quota metadata, as in upstream. No reset is ever performed.
        let credits: UsageResetCredits?
        if let resetData = try? await request(.resetCredits, credential) {
            credits = try? CodexUsage.resetCredits(from: resetData)
        } else { credits = nil }
        return ProviderSnapshot(id: "codex", displayName: "Codex", glyph: .openai,
            fidelity: .official, status: .ok, windows: windows, headlineID: Self.headlineID(in: windows),
            weeklyID: Self.weeklyID(in: windows), plan: CodexUsage.plan(from: data), resetCredits: credits)
    }
    static func headlineID(in windows: [LimitWindow]) -> String {
        // A weekly-only account still has a real account limit to display.
        // Never promote a feature-specific Spark/code-review quota to the headline.
        windows.contains { $0.id == "primary" } ? "primary" : "secondary"
    }
    static func weeklyID(in windows: [LimitWindow]) -> String {
        windows.first { $0.group == nil && abs(($0.duration ?? 0) - 604800) < 60 }?.id ?? "secondary"
    }
    static func request(_ endpoint: CodexEndpoint, _ credential: CodexCredential) -> URLRequest {
        var request = URLRequest(url: endpoint.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        if endpoint == .resetCredits { request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta") }
        return request
    }
    private func request(_ endpoint: CodexEndpoint, _ credential: CodexCredential) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: Self.request(endpoint, credential))
        guard let http = response as? HTTPURLResponse, let url = http.url, CodexEndpoint.allows(url)
        else { bytes.task.cancel(); throw CodexConnectionError.invalidResponse }
        if http.statusCode == 429 {
            bytes.task.cancel()
            let delay = Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After"))
            defaults.set(Date().addingTimeInterval(delay).timeIntervalSince1970, forKey: Self.backoffKey)
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }
        guard http.statusCode == 200 else {
            bytes.task.cancel()
            if http.statusCode == 401 || http.statusCode == 403 { throw UsageProviderError.needsAuth }
            if (300..<400).contains(http.statusCode) { throw CodexConnectionError.redirect }
            throw UsageProviderError.badResponse(status: http.statusCode)
        }
        let maximumBytes = 2 * 1024 * 1024
        guard response.expectedContentLength <= maximumBytes else {
            bytes.task.cancel(); throw CodexConnectionError.oversizedResponse
        }
        var body = Data()
        for try await byte in bytes {
            guard body.count < maximumBytes else {
                bytes.task.cancel(); throw CodexConnectionError.oversizedResponse
            }
            body.append(byte)
        }
        return body
    }
    static func retryDelay(_ header: String?, now: Date = Date()) -> TimeInterval {
        if let header, let seconds = Double(header), seconds.isFinite { return max(60, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let header, let date = formatter.date(from: header) { return max(60, date.timeIntervalSince(now)) }
        return 60
    }
}
