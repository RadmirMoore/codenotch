import Foundation
import CryptoKit

public struct Tokens: Equatable, Sendable, Decodable {
    public var input: Int64 = 0
    public var cached: Int64 = 0
    public var output: Int64 = 0
    public var reasoning: Int64 = 0
    public var total: Int64 = 0

    public init(input: Int64 = 0, cached: Int64 = 0, output: Int64 = 0,
                reasoning: Int64 = 0, total: Int64 = 0) {
        self.input = input; self.cached = cached; self.output = output
        self.reasoning = reasoning; self.total = total
    }

    enum CodingKeys: String, CodingKey {
        case input = "input_tokens", cached = "cached_input_tokens"
        case output = "output_tokens", reasoning = "reasoning_output_tokens", total = "total_tokens"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decode(Int64.self, forKey: .input)
        output = try c.decode(Int64.self, forKey: .output)
        total = try c.decode(Int64.self, forKey: .total)
        cached = try c.decodeIfPresent(Int64.self, forKey: .cached) ?? 0
        reasoning = try c.decodeIfPresent(Int64.self, forKey: .reasoning) ?? 0
        // Reject corrupted/malicious counters before arithmetic. One trillion
        // per session is far beyond useful logs, and keeps subtraction safe.
        guard [input, cached, output, reasoning, total].allSatisfy({ (0...1_000_000_000_000).contains($0) }),
              cached <= input, reasoning <= output, total == input + output else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid token counters"))
        }
    }

    func difference(from old: Tokens) -> Tokens {
        Tokens(input: max(0, input - old.input), cached: max(0, cached - old.cached),
               output: max(0, output - old.output), reasoning: max(0, reasoning - old.reasoning),
               total: max(0, total - old.total))
    }

    public mutating func add(_ other: Tokens) {
        // Aggregation of untrusted files must not overflow even with fabricated logs.
        func sum(_ a: Int64, _ b: Int64) -> Int64 {
            let (value, overflow) = a.addingReportingOverflow(b)
            return overflow ? Int64.max : value
        }
        input = sum(input, other.input); cached = sum(cached, other.cached)
        output = sum(output, other.output); reasoning = sum(reasoning, other.reasoning)
        total = sum(total, other.total)
    }

    var fingerprint: String { "\(input):\(cached):\(output):\(reasoning):\(total)" }
}

struct TokenRecord: Decodable {
    let type: String
    let timestamp: String?
    let payload: Payload

    struct Payload: Decodable {
        let type: String?
        let info: Info?
    }
    struct Info: Decodable { let total_token_usage: Tokens? }
}

struct Contribution: Sendable {
    let id: Data
    let date: Date
    let tokens: Tokens
}

/// Only numeric token fields and timestamps survive parsing. Prompts, paths,
/// account information, and model replies are never retained or logged.
struct RolloutParser {
    private(set) var entries: [Contribution] = []
    private(set) var malformed = 0
    private(set) var resets = 0
    private var previous = Tokens()
    private var pending = Data()
    private var droppingLongLine = false
    static let maximumLineBytes = 1_048_576

    private let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let seconds = ISO8601DateFormatter()

    mutating func feed(_ bytes: Data) {
        // Never retain an unbounded line (e.g. an inline image or tool output).
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes[start...].firstIndex(of: 10) ?? bytes.endIndex
            if !droppingLongLine {
                if pending.count + end - start <= Self.maximumLineBytes {
                    pending.append(contentsOf: bytes[start..<end])
                } else {
                    pending.removeAll(keepingCapacity: false)
                    droppingLongLine = true
                    malformed += 1
                }
            }
            if end < bytes.endIndex {
                if !droppingLongLine { parseLine(pending) }
                pending.removeAll(keepingCapacity: true)
                droppingLongLine = false
                start = end + 1
            } else { break }
        }
        // An unfinished line waits for the next append; never count partial JSON.
    }

    private mutating func parseLine(_ line: Data) {
        // Cheap prefilter: avoid decoding ordinary conversation records.
        guard line.range(of: Data("token_count".utf8)) != nil else { return }
        struct Header: Decodable {
            let type: String
            let payload: Payload
            struct Payload: Decodable { let type: String? }
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: line),
              header.type == "event_msg", header.payload.type == "token_count" else { return }
        guard let event = try? JSONDecoder().decode(TokenRecord.self, from: line) else {
            malformed += 1; return
        }
        guard let totals = event.payload.info?.total_token_usage else { return }
        guard let stamp = event.timestamp,
              let date = fractional.date(from: stamp) ?? seconds.date(from: stamp) else {
            malformed += 1
            return
        }
        // Codex's counters are cumulative, not the cost of each log record.
        // Repeated token_count events (including rate-limit updates) add zero.
        let reset = totals.total < previous.total || totals.input < previous.input || totals.output < previous.output
        if reset { resets += 1 }
        let delta = totals.difference(from: reset ? Tokens() : previous)
        previous = totals
        guard delta.total > 0 else { return }
        // Copied/archived rollouts and the copied prefix of a fork preserve
        // timestamp + cumulative counters. Deduplicate those across files.
        let signature = "\(stamp)|\(totals.fingerprint)"
        entries.append(Contribution(id: Data(SHA256.hash(data: Data(signature.utf8))),
                                    date: date, tokens: delta))
    }
}

public struct CounterSnapshot: Sendable {
    public var today = Tokens()
    public var week = Tokens()
    public var all = Tokens()
    public var files = 0
    public var events = 0
    public var skipped = 0
    public var resets = 0
    public var catchingUp = false
    public var lastEvent: Date?
    public init() {}
}
