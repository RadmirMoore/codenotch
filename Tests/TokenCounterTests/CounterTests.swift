import XCTest
@testable import TokenCounter

final class CounterTests: XCTestCase {
    private var temp: URL!
    private var sessions: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-09-29T20:00:00Z")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        sessions = temp.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }

    private func event(_ input: Int64, _ output: Int64, cached: Int64 = 0, reasoning: Int64 = 0,
                       time: String = "2026-09-29T12:00:00Z") -> String {
        #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(input + output)},"last_token_usage":{"input_tokens":999999}}}}"# + "\n"
    }

    @discardableResult
    private func file(_ contents: String) throws -> URL { try file("one", contents) }

    @discardableResult
    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = sessions.appendingPathComponent("rollout-\(name).jsonl")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8))
    }

    func testCumulativeCountersAreNotSummedAndSubsetsAreNotAddedTwice() async throws {
        let first = event(100, 20, cached: 60, reasoning: 10)
        try file(first + first + event(160, 40, cached: 90, reasoning: 15, time: "2026-09-29T12:01:00Z"))
        let scan = LogScanner()
        let a = await scan.scan(roots: [sessions], now: now, calendar: calendar)
        XCTAssertEqual(a.all, Tokens(input: 160, cached: 90, output: 40, reasoning: 15, total: 200))
        XCTAssertEqual(a.events, 2)
        let again = await scan.scan(roots: [sessions], now: now, calendar: calendar)
        XCTAssertEqual(again.all, a.all)
    }

    func testDailyDeltaCrossesMidnightAndSevenDaysMeansCalendarDays() async throws {
        try file(event(100, 20, time: "2026-09-22T23:59:59Z")
                 + event(200, 40, time: "2026-09-23T00:00:00Z")
                 + event(300, 60, time: "2026-09-28T23:59:59Z")
                 + event(350, 70, time: "2026-09-29T00:00:00.001Z"))
        let s = await LogScanner().scan(roots: [sessions], now: now, calendar: calendar)
        XCTAssertEqual(s.all.total, 420)
        XCTAssertEqual(s.week.total, 300)
        XCTAssertEqual(s.today.total, 60)
    }

    func testPartialAppendIsCountedOnlyAfterNewline() async throws {
        let text = event(100, 20)
        let url = try file(String(text.prefix(80)))
        let scan = LogScanner()
        let partial = await scan.scan(roots: [sessions], now: now, calendar: calendar)
        XCTAssertEqual(partial.all.total, 0)
        try append(String(text.dropFirst(80)), to: url)
        let complete = await scan.scan(roots: [sessions], now: now, calendar: calendar)
        XCTAssertEqual(complete.all.total, 120)
    }

    func testCopiesAndArchivedFilesAreDeduplicated() async throws {
        let contents = event(100, 20)
        try file("one", contents)
        try file("copy", contents)
        let archive = temp.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: archive.appendingPathComponent("rollout-archive.jsonl"))
        let result = await LogScanner().scan(roots: [sessions, archive], now: now, calendar: calendar)
        XCTAssertEqual(result.all.total, 120)
        XCTAssertEqual(result.events, 1)
        XCTAssertEqual(result.files, 3)
    }

    func testForkPrefixIsDeduplicatedButIndependentUsageCounts() async throws {
        let prefix = event(100, 20)
        try file("parent", prefix + event(130, 30, time: "2026-09-29T12:01:00Z"))
        try file("fork", prefix + event(140, 40, time: "2026-09-29T12:02:00Z"))
        let result = await LogScanner().scan(roots: [sessions], now: now, calendar: calendar)
        XCTAssertEqual(result.all.total, 220) // 120 + 40 + 60
    }

    func testTruncateReplaceDeleteAndForgetDoNotRetainOldTotals() async throws {
        let url = try file(event(10000, 2000))
        let scanner = LogScanner()
        _ = await scanner.scan(roots: [sessions], now: now, calendar: calendar)
        try Data(event(10, 2).utf8).write(to: url)
        let small = await scanner.scan(roots: [sessions], now: now, calendar: calendar)
        XCTAssertEqual(small.all.total, 12)
        try Data(event(20, 4).utf8).write(to: url, options: .atomic)
        let replaced = await scanner.scan(roots: [sessions], now: now, calendar: calendar)
        XCTAssertEqual(replaced.all.total, 24)
        try FileManager.default.removeItem(at: url)
        let removed = await scanner.scan(roots: [sessions], now: now, calendar: calendar)
        XCTAssertEqual(removed.all.total, 0)
        try file(event(100, 20))
        _ = await scanner.scan(roots: [sessions], now: now, calendar: calendar)
        let forgotten = await scanner.scan(roots: [], now: now, calendar: calendar)
        XCTAssertEqual(forgotten.all.total, 0)
    }

    func testCounterResetStartsANewSegment() async throws {
        try file(event(100, 20) + event(10, 2, time: "2026-09-29T12:01:00Z"))
        let result = await LogScanner().scan(roots: [sessions], now: now, calendar: calendar)
        XCTAssertEqual(result.all.total, 132)
        XCTAssertEqual(result.resets, 1)
    }

    func testRejectsSymlinkFilesDirectoriesHardlinksAndOtherFiles() async throws {
        let outside = temp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("rollout-secret.jsonl")
        try Data(event(999, 1).utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("rollout-link.jsonl"), withDestinationURL: secret)
        try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("linked-directory"), withDestinationURL: outside)
        try FileManager.default.linkItem(at: secret, to: sessions.appendingPathComponent("rollout-hard.jsonl"))
        try Data(event(777, 1).utf8).write(to: sessions.appendingPathComponent("auth.json"))
        try file(event(10, 2))
        let result = await LogScanner().scan(roots: [sessions], now: now, calendar: calendar)
        XCTAssertEqual(result.all.total, 12)
        XCTAssertEqual(result.files, 1)
        XCTAssertGreaterThanOrEqual(result.skipped, 3)
        let wrongRoot = await LogScanner().scan(roots: [temp], now: now, calendar: calendar)
        XCTAssertEqual(wrongRoot.files, 0)
    }

    func testBudgetedScanningEventuallyFinishesWithoutDoubleCounting() async throws {
        try file(event(100, 20) + event(200, 40, time: "2026-09-29T12:01:00Z"))
        let scanner = LogScanner()
        var result = CounterSnapshot()
        for _ in 0..<100 {
            result = await scanner.scan(roots: [sessions], now: now, calendar: calendar, byteBudget: 37)
            if !result.catchingUp { break }
        }
        XCTAssertFalse(result.catchingUp)
        XCTAssertEqual(result.all.total, 240)
    }

    func testOversizedLineMalformedCountersAndUnrelatedMessages() {
        var parser = RolloutParser()
        parser.feed(Data(repeating: 65, count: RolloutParser.maximumLineBytes + 100))
        parser.feed(Data(("\n" + event(100, 20)).utf8))
        parser.feed(Data(event(-1, 20).utf8))
        parser.feed(Data(event(100, 20, cached: 101).utf8))
        parser.feed(Data(#"{"type":"response_item","payload":{"type":"message","text":"token_count secret-do-not-store"}}"#.utf8))
        parser.feed(Data("\n".utf8))
        XCTAssertEqual(parser.entries.count, 1)
        XCTAssertEqual(parser.entries[0].tokens.total, 120)
        XCTAssertEqual(parser.malformed, 3)
    }

    func testRateOnlyUpdatesAndFutureEventsDoNotCount() async throws {
        try file(#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"# + "\n"
                 + event(100, 20, time: "2099-01-01T00:00:00Z"))
        let result = await LogScanner().scan(roots: [sessions], now: now, calendar: calendar)
        XCTAssertEqual(result.all.total, 0)
    }
}
