import XCTest
@testable import CodenotchLocal

final class CodexSecurityTests: XCTestCase {
    private let valid = Data(#"{"tokens":{"access_token":"test-token","account_id":"test-account","refresh_token":"must-not-be-sent","id_token":"must-not-be-sent"}}"#.utf8)
    func testRequestsSendOnlyAccessTokenAndAccountToExactHTTPSRoutes() throws {
        let credential = try CodexCredential.decode(valid)
        for endpoint in CodexEndpoint.allCases {
            let request = CodexConnection.request(endpoint, credential)
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "chatgpt.com")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "test-account")
            XCTAssertFalse(String(describing: request.allHTTPHeaderFields).contains("must-not-be-sent"))
        }
    }
    func testLookalikesHTTPPortsAndUnexpectedRoutesAreRejected() {
        for address in ["http://chatgpt.com/backend-api/wham/usage", "https://chatgpt.com.evil.test/backend-api/wham/usage", "https://evil.test", "https://chatgpt.com/backend-api/wham/usage?token=x", "https://chatgpt.com:8443/backend-api/wham/usage", "https://chatgpt.com/backend-api/wham/reset"] {
            XCTAssertFalse(CodexEndpoint.allows(URL(string: address)!))
        }
    }
    func testRedirectCannotForwardAuthorizationEvenToSameHost() {
        let delegate = RejectRedirects()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for destination in ["https://evil.test", "https://chatgpt.com/unexpected"] {
            let request = URLRequest(url: URL(string: destination)!)
            let task = session.dataTask(with: CodexEndpoint.usage.url) // never resumed
            let response = HTTPURLResponse(url: CodexEndpoint.usage.url, statusCode: 302, httpVersion: nil, headerFields: ["Location": destination])!
            var answered = false
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                XCTAssertNil($0); answered = true
            }
            XCTAssertTrue(answered)
        }
    }
    func testInvalidCredentialAndHeaderInjectionAreRejected() {
        for body in [#"{"tokens":{"access_token":"","account_id":"x"}}"#, #"{"tokens":{"access_token":"abc\r\nX-Evil: y","account_id":"x"}}"#, #"{"tokens":{"refresh_token":"x"}}"#, "null"] {
            XCTAssertThrowsError(try CodexCredential.decode(Data(body.utf8)))
        }
        XCTAssertThrowsError(try CodexCredential.decode(Data(repeating: 65, count: CodexCredential.maximumBytes + 1)))
    }
    func testReadOnlyFileReopensRotationsAndRefusesSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("auth.json")
        try valid.write(to: file)
        XCTAssertEqual(try CodexCredential.read(file).accessToken, "test-token")
        XCTAssertEqual(try Data(contentsOf: file), valid)
        let rotated = Data(#"{"tokens":{"access_token":"rotated","account_id":"other"}}"#.utf8)
        try rotated.write(to: file, options: .atomic)
        XCTAssertEqual(try CodexCredential.read(file).accessToken, "rotated")
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try CodexCredential.read(link))
        XCTAssertThrowsError(try CodexCredential.read(directory))
    }
    func testRetryAfterBothFormatsAndMinimumDelay() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(CodexConnection.retryDelay("120", now: now), 120)
        XCTAssertEqual(CodexConnection.retryDelay("Thu, 01 Jan 1970 00:03:00 GMT", now: now), 180)
        for header in [nil, "NaN", "-20", "0", "bad"] { XCTAssertEqual(CodexConnection.retryDelay(header, now: now), 60) }
    }
    func testRingNumberShowsRemainingAndPreservesUsedFractionForWarnings() {
        let snapshot = ProviderSnapshot(id: "codex", displayName: "Codex", glyph: .openai, fidelity: .official, status: .ok,
          windows: [LimitWindow(id: "primary", label: "5h", usedFraction: 0.75)], headlineID: "primary")
        XCTAssertEqual(snapshot.headlineText, "25%")
        XCTAssertEqual(snapshot.usedFraction, 0.75)
    }
    func testWeeklyOnlyAccountHasAHeadlineWithoutDuplicatedWeeklyRing() {
        let windows = [LimitWindow(id: "secondary", label: "Weekly", usedFraction: 0.56, duration: 604800)]
        let snapshot = ProviderSnapshot(id: "codex", displayName: "Codex", glyph: .openai, fidelity: .official, status: .ok,
          windows: windows, headlineID: CodexConnection.headlineID(in: windows), weeklyID: CodexConnection.weeklyID(in: windows))
        XCTAssertEqual(snapshot.headlineText, "44%")
        XCTAssertNil(snapshot.weeklyWindow)
        XCTAssertNotEqual(CodexConnection.headlineID(in: [LimitWindow(id: "spark", label: "Spark", usedFraction: 0.5)]), "spark")
    }

}
