import XCTest
@testable import CodenotchLocal

final class CodexUsageTests: XCTestCase {
    private func windows(_ json: String) throws -> [LimitWindow] {
        try CodexUsage.windows(from: Data(json.utf8), now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testBothWindowsAreReadWhenBothArePresent() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":1800001000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":1800600000}},
         "additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
          "primary_window":{"used_percent":99,"limit_window_seconds":18000}}}],
         "code_review_rate_limit":{
           "primary_window":{"used_percent":90,"limit_window_seconds":604800},
           "secondary_window":{"used_percent":15,"limit_window_seconds":18000}},
         "credits":{"balance":"100"},"model_usage":{"spark":99}}
        """)
        // Spark is 99% used and listed first in the extras, but the ring
        // follows `windows.first`, which has to stay the main primary.
        XCTAssertEqual(result.map(\.duration), [18000, 604800, 18000, 604800, 18000])
        XCTAssertEqual(result.map(\.id),
                       ["primary", "secondary", "spark", "code-review", "code-review-secondary"])
        XCTAssertEqual(result.map(\.group),
                       [nil, nil, "Spark", "Code review", "Code review"] as [String?])
        XCTAssertEqual(result.map(\.label),
                       ["5h limit", "Weekly limit", "5h limit", "Weekly limit", "5h limit"])
        XCTAssertEqual(result.map(\.usedFraction), [0.25, 0.10, 0.99, 0.90, 0.15])
        XCTAssertEqual(result.first?.id, "primary")
        XCTAssertEqual(result.first?.resetsAt, Date(timeIntervalSince1970: 1_800_001_000))
    }

    /// The reported case: a free-plan account's primary window was 30 days,
    /// not 5 hours or 7 — recorded from a live request. The old parser only
    /// recognised two fixed durations and silently dropped anything else,
    /// which on this exact account meant every window vanished and the ring
    /// reported nothing metered on an account that was genuinely 16% through
    /// a real limit.
    func testAMonthlyPrimaryWindowIsNotDropped() throws {
        let result = try windows("""
        {"rate_limit":{"primary_window":{"used_percent":16,"limit_window_seconds":2592000,
        "reset_after_seconds":1838382,"reset_at":1790585722},"secondary_window":null},
         "plan_type":"free"}
        """)
        XCTAssertEqual(result.map(\.id), ["primary"])
        XCTAssertEqual(CodexUsage.plan(from: Data("""
        {"rate_limit":{"primary_window":{"used_percent":16,"limit_window_seconds":2592000}},
         "plan_type":"free"}
        """.utf8)), "free")
        XCTAssertEqual(result.first?.label, "Monthly limit")
        XCTAssertEqual(result.first?.usedFraction ?? -1, 0.16, accuracy: 0.0001)
    }

    func testPaceUsesTheReportedCycleRegardlessOfPlanName() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for seconds in [18000, 604800, 2592000] {
            let result = try CodexUsage.windows(from: Data("""
            {"rate_limit":{"primary_window":{"used_percent":80,
            "limit_window_seconds":\(seconds),"reset_after_seconds":\(seconds / 2)}}}
            """.utf8), now: now)
            let window = try XCTUnwrap(result.first)
            XCTAssertEqual(window.duration, Double(seconds))
            XCTAssertEqual(try XCTUnwrap(window.usagePace(now: now)).percentagePoints, 30,
                           accuracy: 0.00001)
        }
    }

    /// A duration that is none of the named buckets still gets a usable label
    /// instead of being the thing that makes the fetch fail.
    func testAnUnrecognisedDurationStillGetsALabel() throws {
        let result = try windows("""
        {"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":259200}}}
        """)
        XCTAssertEqual(result.first?.label, "3d limit")
    }

    // The endpoint can put a weekly-only allowance in primary_window.
    func testANullSecondaryIsDropped() throws {
        let result = try windows("""
        {"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":604800,
        "reset_after_seconds":604119,"reset_at":1789308033},"secondary_window":null}}
        """)
        XCTAssertEqual(result.map(\.id), ["primary"])
        XCTAssertEqual(result.first?.label, "Weekly limit")
        XCTAssertEqual(result.first?.resetsAt, Date(timeIntervalSince1970: 1_789_308_033))
    }

    func testStillReadsACountdownIfABuildEmitsOne() throws {
        let result = try windows("""
        {"rate_limit":{
        "primary_window":{"used_percent":8,"limit_window_seconds":604800},
        "secondary_window":{"used_percent":0,"limit_window_seconds":18000,"reset_after_seconds":120}}}
        """)
        XCTAssertEqual(result.map(\.duration), [604800, 18000])
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.first?.usedFraction, 0.08)
        XCTAssertNil(result.first?.resetsAt)
        XCTAssertEqual(result.last?.usedFraction, 0)
        XCTAssertEqual(result.last?.resetsAt, Date(timeIntervalSince1970: 1_800_000_120))
    }

    /// The reported symptom: the tooltip showed only the weekly window and the
    /// ring showed a dash. A null `used_percent` on one window threw the whole
    /// fetch away, so a good weekly window was hidden behind the bad hourly
    /// one. One malformed window is skipped, not fatal.
    func testAWindowMissingUsedPercentIsSkippedRatherThanFailing() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":null,"limit_window_seconds":18000,"reset_at":1800001000},
          "secondary_window":{"used_percent":29,"limit_window_seconds":604800,"reset_at":1800600000}}}
        """)
        XCTAssertEqual(result.map(\.id), ["secondary"])
        XCTAssertEqual(result.first?.label, "Weekly limit")
        XCTAssertEqual(result.first?.usedFraction ?? -1, 0.29, accuracy: 0.0001)
    }

    /// A window without a duration still gets a fallback label instead of
    /// failing the decode of the whole response.
    func testAWindowMissingItsDurationStillParses() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":8,"reset_at":1800001000},
          "secondary_window":{"used_percent":42,"limit_window_seconds":604800,"reset_at":1800600000}}}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.first?.label, "Current session")
        XCTAssertEqual(result.last?.label, "Weekly limit")
    }

    /// Both windows malformed is still an error, not an empty success — the
    /// store turns it into "waiting", not a silent 0%. A decode failure used
    /// to surface as `badResponse` instead, which looks like a broken fetch.
    func testBothWindowsMissingLeavesNothingMetered() {
        XCTAssertThrowsError(try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":null,"limit_window_seconds":18000},
          "secondary_window":null}}
        """)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    /// Spark meters a 5-hour window and a weekly one, same lengths as the
    /// main pair. Both belong on the hover card, grouped together. Extras
    /// alone are still a valid reading.
    func testSparkFiveHourAndWeeklyWindowsAreRead() throws {
        let result = try windows("""
        {"additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
          "primary_window":{"used_percent":40,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":70,"limit_window_seconds":604800}}}]}
        """)
        XCTAssertEqual(result.map(\.id), ["spark", "spark-secondary"])
        XCTAssertEqual(result.map(\.group), ["Spark", "Spark"] as [String?])
        XCTAssertEqual(result.map(\.label), ["5h limit", "Weekly limit"])
        XCTAssertEqual(result.map(\.usedFraction), [0.40, 0.70])
    }

    /// An additional limit that is not Spark is not a window we show.
    func testAnUnknownAdditionalLimitIsIgnored() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":25,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800}},
         "additional_rate_limits":[{"limit_name":"Credits","rate_limit":{
          "primary_window":{"used_percent":50,"limit_window_seconds":86400}}}]}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.map(\.usedFraction), [0.25, 0.10])
    }

    /// A null `used_percent` on Spark must not fail a fetch that already has
    /// a good main pair — same skip rule as the main windows. Code review's
    /// weekly used to vanish with its 5h sibling when that object had no
    /// percent at all.
    func testANullExtraUsedPercentIsSkippedRatherThanFailing() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":25,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800}},
         "additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
          "primary_window":{"used_percent":null,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":40,"limit_window_seconds":604800}}}],
         "code_review_rate_limit":{
           "primary_window":{"limit_window_seconds":604800},
           "secondary_window":{"used_percent":8,"limit_window_seconds":18000}}}
        """)
        XCTAssertEqual(result.map(\.id),
                       ["primary", "secondary", "spark-secondary", "code-review-secondary"])
        XCTAssertEqual(result.map(\.group),
                       [nil, nil, "Spark", "Code review"] as [String?])
        XCTAssertEqual(result.map(\.label),
                       ["5h limit", "Weekly limit", "Weekly limit", "5h limit"])
        XCTAssertEqual(result.map(\.usedFraction), [0.25, 0.10, 0.40, 0.08])
    }

    /// An unreadable 5h object (string percent, not a number) used to fail
    /// the whole RateLimit decode, so code review's weekly never appeared.
    func testAMalformedCodeReviewPrimaryDoesNotDropItsSecondary() throws {
        let result = try windows("""
        {"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":18000}},
         "code_review_rate_limit":{
           "primary_window":{"used_percent":"n/a","limit_window_seconds":604800},
           "secondary_window":{"used_percent":8,"limit_window_seconds":18000}}}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "code-review-secondary"])
        XCTAssertEqual(result.last?.group, "Code review")
        XCTAssertEqual(result.last?.usedFraction ?? -1, 0.08, accuracy: 0.0001)
    }

    /// Same skip rule on the main pair: a non-numeric percent must not turn
    /// a good weekly window (or a good Spark extra) into a failed fetch.
    func testAMalformedMainWindowDoesNotFailTheRest() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":"n/a","limit_window_seconds":18000},
          "secondary_window":{"used_percent":29,"limit_window_seconds":604800}},
         "additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
          "primary_window":{"used_percent":40,"limit_window_seconds":18000}}}]}
        """)
        XCTAssertEqual(result.map(\.id), ["secondary", "spark"])
        XCTAssertEqual(result.first?.id, "secondary")
        XCTAssertEqual(result.map(\.usedFraction), [0.29, 0.40])
    }

    /// An empty additional_rate_limits array is the same as omitting it.
    func testEmptyAdditionalRateLimitsLeaveTheMainWindowsUnchanged() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":25,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800}},
         "additional_rate_limits":[]}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "secondary"])
        XCTAssertEqual(result.map(\.label), ["5h limit", "Weekly limit"])
        XCTAssertEqual(result.map(\.usedFraction), [0.25, 0.10])
        XCTAssertEqual(result.map(\.group), [nil, nil] as [String?])
    }

    /// The additional limit is named after the model, not "Spark", and still
    /// maps to the spark window id — via `limit_name` or `metered_feature`.
    /// Matching only the exact word "spark" used to drop GPT-5.3-Codex-Spark.
    func testGPT53CodexSparkStillMapsToSpark() throws {
        for field in ["limit_name", "metered_feature"] {
            let result = try windows("""
            {"rate_limit":{
              "primary_window":{"used_percent":25,"limit_window_seconds":18000}},
             "additional_rate_limits":[{"\(field)":"GPT-5.3-Codex-Spark","rate_limit":{
              "primary_window":{"used_percent":99,"limit_window_seconds":18000},
              "secondary_window":{"used_percent":5,"limit_window_seconds":604800}}}]}
            """)
            XCTAssertEqual(result.map(\.id), ["primary", "spark", "spark-secondary"], field)
            XCTAssertEqual(result.map(\.group), [nil, "Spark", "Spark"] as [String?], field)
            XCTAssertEqual(result.map(\.label), ["5h limit", "5h limit", "Weekly limit"], field)
            XCTAssertEqual(result.dropFirst().map(\.usedFraction), [0.99, 0.05], field)
        }
    }

    /// Credits and `codex_other` are real extras on some accounts. Showing
    /// them as windows made the hover card grow by a row that has no home.
    func testUnknownExtrasAloneLeaveNothingMetered() {
        XCTAssertThrowsError(try windows("""
        {"additional_rate_limits":[{"limit_name":"Credits","metered_feature":"codex_other",
          "rate_limit":{"primary_window":{"used_percent":50,"limit_window_seconds":86400}}}]}
        """)) { error in
            guard case UsageProviderError.nothingMetered = error else {
                return XCTFail("expected nothingMetered, got \(error)")
            }
        }
    }

    /// Code review with no main pair is still a reading, same as Spark-only.
    func testCodeReviewAloneIsStillMetered() throws {
        let result = try windows("""
        {"code_review_rate_limit":{
          "primary_window":{"used_percent":90,"limit_window_seconds":604800},
          "secondary_window":{"used_percent":15,"limit_window_seconds":18000}}}
        """)
        XCTAssertEqual(result.map(\.id), ["code-review", "code-review-secondary"])
        XCTAssertEqual(result.map(\.group), ["Code review", "Code review"] as [String?])
        XCTAssertEqual(result.map(\.usedFraction), [0.90, 0.15])
    }

    /// Extras listed first in the JSON must not become `windows.first`.
    func testSparkListedBeforeMainStillFollowsTheMainPair() throws {
        let result = try windows("""
        {"additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
          "primary_window":{"used_percent":99,"limit_window_seconds":18000}}}],
         "code_review_rate_limit":{"primary_window":{"used_percent":90,"limit_window_seconds":604800}},
         "rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800}}}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "secondary", "spark", "code-review"])
        XCTAssertEqual(result.first?.id, "primary")
        XCTAssertEqual(result.first?.usedFraction, 0.25)
    }

    /// A payload that names Spark twice (the generic limit and the model
    /// feature) must not emit two 5h rows with the same id. Duplicate ids
    /// make the tooltip ForEach and Phone Link list explode, and the second
    /// ungrouped "5h limit" reads as another session window.
    func testTwoSparkExtrasDoNotDuplicateWindowIDs() throws {
        let result = try windows("""
        {"rate_limit":{
          "primary_window":{"used_percent":25,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800}},
         "additional_rate_limits":[
           {"limit_name":"Spark","rate_limit":{
             "primary_window":{"used_percent":40,"limit_window_seconds":18000}}},
           {"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"spark","rate_limit":{
             "primary_window":{"used_percent":99,"limit_window_seconds":18000},
             "secondary_window":{"used_percent":12,"limit_window_seconds":604800}}}
         ]}
        """)
        XCTAssertEqual(result.map(\.id), ["primary", "secondary", "spark", "spark-secondary"])
        XCTAssertEqual(Set(result.map(\.id)).count, result.count)
        XCTAssertEqual(result.map(\.group), [nil, nil, "Spark", "Spark"] as [String?])
        XCTAssertEqual(result.map(\.label), ["5h limit", "Weekly limit", "5h limit", "Weekly limit"])
        XCTAssertEqual(result.map(\.usedFraction), [0.25, 0.10, 0.40, 0.12])
    }

    /// Hiding extras must drop Spark and code review rather than leaving an
    /// empty success when those were the only windows.
    func testHidingExtrasDropsSparkAndCodeReview() throws {
        let json = """
        {"rate_limit":{
          "primary_window":{"used_percent":25,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800}},
         "additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
          "primary_window":{"used_percent":99,"limit_window_seconds":18000}}}],
         "code_review_rate_limit":{"primary_window":{"used_percent":90,"limit_window_seconds":604800}}}
        """
        let hidden = try CodexUsage.windows(
            from: Data(json.utf8), now: Date(timeIntervalSince1970: 1_800_000_000),
            includeExtras: false
        )
        XCTAssertEqual(hidden.map(\.id), ["primary", "secondary"])
        XCTAssertThrowsError(try CodexUsage.windows(
            from: Data("""
            {"additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
              "primary_window":{"used_percent":40,"limit_window_seconds":18000}}}]}
            """.utf8), includeExtras: false
        ))
    }

    func testDecodesProfileTokenUsageAndBuildsAThirtyDaySeries() throws {
        let json = """
        {"profile":{"display_name":"Test"},
         "stats":{"lifetime_tokens":1200,"peak_daily_tokens":300,
         "longest_running_turn_sec":4020,"current_streak_days":2,"longest_streak_days":11,
         "daily_usage_buckets":[
           {"start_date":"2026-08-12","tokens":100},
           {"start_date":"2026-09-03","tokens":200},
           {"start_date":"2026-09-08","tokens":300}
         ]}}
        """
        let usage = try CodexUsage.profileUsage(from: Data(json.utf8))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9))!

        XCTAssertEqual(usage.last30Days(now: now, calendar: calendar).count, 30)
        XCTAssertEqual(usage.last30Days(now: now, calendar: calendar).first?.startDate,
                       "2026-08-11")
        XCTAssertEqual(usage.usageInLast30Days(now: now, calendar: calendar), 600)
        XCTAssertEqual(usage.peakDailyTokens, 300)
        XCTAssertEqual(usage.summary?.lifetimeTokens, 1200)
        XCTAssertEqual(usage.summary?.peakDailyTokens, 300)
        XCTAssertEqual(usage.summary?.longestRunningTurnSeconds, 4020)
        XCTAssertEqual(usage.summary?.currentStreakDays, 2)
        XCTAssertEqual(usage.summary?.longestStreakDays, 11)
        XCTAssertEqual(usage.usageToday(now: now, calendar: calendar), nil,
                       "a missing current-day bucket should be shown as Pending")
    }

    /// `/wham/rate-limit-reset-credits` reports how many unused resets remain
    /// and when the next one expires. The count is its own field because the
    /// credits array can be truncated.
    func testResetCreditsReadsAvailableCountAndSoonestExpiry() throws {
        let json = """
        {"credits":[
          {"id":"later","reset_type":"rate_limit","status":"available",
           "granted_at":"2026-09-01T12:00:00Z",
           "expires_at":"2026-09-20T12:00:00.250Z",
           "title":"Reset","description":"Unused reset","extra":true},
          {"id":"spent","reset_type":"rate_limit","status":"redeemed",
           "granted_at":"2026-08-01T00:00:00Z",
           "expires_at":"2026-09-12T00:00:00Z"},
          {"id":"sooner","reset_type":"rate_limit","status":"available",
           "granted_at":"2026-09-02T00:00:00Z",
           "expires_at":"2026-09-15T08:00:00Z"}
         ],
         "available_count":2,
         "server_time":"2026-09-10T00:00:00Z"}
        """
        let result = try CodexUsage.resetCredits(from: Data(json.utf8))
        XCTAssertEqual(result.availableCount, 2)
        XCTAssertEqual(result.credits.map(\.id), ["later", "spent", "sooner"])
        XCTAssertEqual(result.available.map(\.id), ["sooner", "later"])
        XCTAssertEqual(result.nextExpiry, ISO8601DateFormatter().date(from: "2026-09-15T08:00:00Z"))

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(result.available.last?.expiresAt,
                       fractional.date(from: "2026-09-20T12:00:00.250Z"))
    }

    func testResetCreditsTrustsAvailableCountWhenTheArrayIsTruncated() throws {
        let result = try CodexUsage.resetCredits(from: Data("""
        {"available_count":3,"credits":[
          {"id":"only","status":"available","expires_at":"2026-09-18T00:00:00Z"}
        ]}
        """.utf8))
        XCTAssertEqual(result.availableCount, 3)
        XCTAssertEqual(result.credits.map(\.id), ["only"])
        XCTAssertEqual(result.available.count, 1)
        XCTAssertEqual(result.nextExpiry, ISO8601DateFormatter().date(from: "2026-09-18T00:00:00Z"))
    }

    func testResetCreditsCountsAvailableCreditsWhenThePayloadOmitsTheCount() throws {
        let result = try CodexUsage.resetCredits(from: Data("""
        {"credits":[
          {"id":"a","status":"available","expires_at":"2026-09-18T00:00:00Z"},
          {"id":"b","status":"redeemed","expires_at":"2026-09-10T00:00:00Z"}
        ]}
        """.utf8))
        XCTAssertEqual(result.availableCount, 1)
        XCTAssertEqual(result.available.map(\.id), ["a"])
    }

    /// A non-object entry is skipped; an unreadable date becomes no expiry.
    /// None of that is a reason to fail the usage fetch.
    func testResetCreditsSkipsMalformedCreditsRatherThanFailing() throws {
        let result = try CodexUsage.resetCredits(from: Data("""
        {"credits":[
          "nope",
          {"id":"ok","status":"available","expires_at":null}
        ],"available_count":1}
        """.utf8))
        XCTAssertEqual(result.credits.map(\.id), ["ok"])
        XCTAssertNil(result.credits.first?.expiresAt)
        XCTAssertEqual(result.availableCount, 1)
        XCTAssertNil(result.nextExpiry)
    }

    func testResetCreditsThrowsOnlyOnInvalidJSON() throws {
        XCTAssertThrowsError(try CodexUsage.resetCredits(from: Data("not-json".utf8))) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
        XCTAssertEqual(try CodexUsage.resetCredits(from: Data("{}".utf8)).availableCount, 0)
        XCTAssertEqual(try CodexUsage.resetCredits(from: Data("[]".utf8)).credits, [])
    }

    func testAccountUsageCardGetsRoomForTheActivitySection() {
        let plain = NotchLayout.cardHeight(windowCount: 2)
        let withTokens = NotchLayout.cardHeight(windowCount: 2, hasTokenUsage: true)

        XCTAssertGreaterThan(withTokens, plain)
        XCTAssertEqual(
            withTokens - plain,
            NotchLayout.codexUsageTop + NotchLayout.hairline + NotchLayout.blockSpacing
                + NotchLayout.codexMetricTop + NotchLayout.codexMetricHeight
                + NotchLayout.codexMetricBottom
                + NotchLayout.hairline
                + 2 * NotchLayout.cardBodyLineHeight
                + NotchLayout.codexUsageRowGap
                + NotchLayout.codexChartTop + NotchLayout.codexChartHeight,
            accuracy: 0.001
        )
    }

}
