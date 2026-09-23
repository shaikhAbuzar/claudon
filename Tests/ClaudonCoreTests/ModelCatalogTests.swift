import Foundation
import Testing
@testable import ClaudonCore

@Test func displayNamesCoverOldAndNewIdStyles() {
    #expect(ModelCatalog.info(for: "claude-fable-5-1").displayName == "Fable 5.1")
    #expect(ModelCatalog.info(for: "claude-opus-5-5").displayName == "Opus 5.5")
    #expect(ModelCatalog.info(for: "claude-haiku-4-5-20251001").displayName == "Haiku 4.5")
    #expect(ModelCatalog.info(for: "claude-3-5-sonnet-20241022").displayName == "Sonnet 3.5")
    #expect(ModelCatalog.info(for: "claude-opus-4-20250514").displayName == "Opus 4")
    #expect(ModelCatalog.info(for: "us.anthropic.claude-haiku-4-5-20251001-v1:0").displayName == "Haiku 4.5")
    #expect(ModelCatalog.info(for: "claude-opus-4-1@20250805").displayName == "Opus 4.1")
    #expect(ModelCatalog.info(for: "claude-opus-5#fast").displayName == "Opus 5 (fast)")
    #expect(ModelCatalog.info(for: "some-local-model").displayName == "some-local-model")
}

@Test func pricesFollowTheListAndCacheMultipliers() throws {
    let million = TokenCounts(input: 1_000_000, output: 1_000_000, cacheWrite5m: 1_000_000,
                              cacheWrite1h: 1_000_000, cacheRead: 1_000_000)
    let fable51 = try #require(ModelCatalog.info(for: "claude-fable-5-1").price)
    #expect(abs(fable51.cost(of: million) - (10 + 50 + 12.5 + 20 + 0.25)) < 1e-9)
    let fable5 = try #require(ModelCatalog.info(for: "claude-fable-5").price)
    #expect(abs(fable5.cacheRead - 1) < 1e-9)
    let opus55 = try #require(ModelCatalog.info(for: "claude-opus-5-5").price)
    #expect(abs(opus55.cost(of: million) - (4 + 20 + 5 + 8 + 0.2)) < 1e-9)
    let sonnet5 = try #require(ModelCatalog.info(for: "claude-sonnet-5").price)
    #expect(sonnet5.input == 2 && sonnet5.output == 10)

    let fast = try #require(ModelCatalog.info(for: "claude-opus-5#fast").price)
    #expect(fast.input == 10 && fast.output == 50)
    // Fast mode isn't offered on Opus 4.7, so it bills at standard rates.
    #expect(ModelCatalog.info(for: "claude-opus-4-7#fast").price == ModelCatalog.info(for: "claude-opus-4-7").price)

    // A version newer than the table is estimated at the family's newest price.
    #expect(ModelCatalog.info(for: "claude-sonnet-6").price == ModelCatalog.info(for: "claude-sonnet-5").price)
    #expect(ModelCatalog.info(for: "some-local-model").price == nil)
}

@Test func parsesTranscriptAndApiTimestamps() throws {
    let base = try #require(ISO8601DateFormatter().date(from: "2026-09-23T05:27:27Z")).timeIntervalSince1970
    let parsed = try #require(Timestamp.parse("2026-09-23T05:27:27.146Z"))
    #expect(abs(parsed - (base + 0.146)) < 1e-6)
    #expect(Timestamp.parse("1970-01-01T00:00:00.000Z") == 0)
    #expect(Timestamp.parse("2026-02-28T23:59:59Z").map { $0 + 1 } == Timestamp.parse("2026-03-01T00:00:00Z"))

    let utc = try #require(Timestamp.parse("2026-09-23T10:09:59.532362+00:00"))
    let india = try #require(Timestamp.parse("2026-09-23T15:39:59.532362+05:30"))
    #expect(abs(utc - india) < 1e-6)
    #expect(Timestamp.parse("not a date") == nil)
}
