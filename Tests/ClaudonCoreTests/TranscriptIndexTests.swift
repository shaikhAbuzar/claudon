import Foundation
import Testing
@testable import ClaudonCore

/// A throwaway `projects` folder shaped like Claude Code's.
private final class Fixture {
    let root: URL
    let stateURL: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("claudon-tests-\(UUID().uuidString)")
        root = base.appendingPathComponent("projects")
        stateURL = base.appendingPathComponent("state/index.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    func index() -> TranscriptIndex { TranscriptIndex(roots: [root], stateURL: stateURL) }

    @discardableResult
    func write(_ relativePath: String, _ lines: [String], newlineAtEnd: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = lines.joined(separator: "\n")
        if newlineAtEnd { text += "\n" }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func append(_ relativePath: String, _ lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent(relativePath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }
}

private func assistant(id: String, request: String = "req_1", model: String = "claude-opus-5",
                       time: String = "2026-09-20T10:00:00.000Z", input: Int = 10, output: Int = 5,
                       cacheWrite: Int = 0, cacheRead: Int = 0, cwd: String = "/Users/me/proj",
                       usageExtra: String = "") -> String {
    #"{"parentUuid":null,"isSidechain":false,"cwd":"\#(cwd)","sessionId":"s1","message":{"id":"\#(id)","type":"message","role":"assistant","model":"\#(model)","content":[{"type":"text","text":"a quote: \"type\":\"assistant\""}],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheWrite),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output)\#(usageExtra)}},"requestId":"\#(request)","type":"assistant","uuid":"u","timestamp":"\#(time)"}"#
}

private let userRow = #"{"type":"user","message":{"role":"user","content":"please look at \"type\":\"assistant\""},"timestamp":"2026-09-20T09:59:00.000Z","cwd":"/Users/me/proj"}"#

private func totals(_ rollup: UsageRollup) -> TokenCounts {
    rollup.buckets.reduce(.zero) { $0 + $1.counts }
}

private func tokens(_ rollup: UsageRollup, model: String) -> Int64 {
    guard let index = rollup.models.firstIndex(of: model) else { return 0 }
    return rollup.buckets.filter { $0.key.model == Int32(index) }.reduce(0) { $0 + $1.counts.total }
}

@Test func countsEachReplyOnceUsingItsFinalRow() throws {
    let fixture = try Fixture()
    try fixture.write("-Users-me-proj/s1.jsonl", [
        userRow,
        assistant(id: "msg_a", output: 7, cacheWrite: 100),
        assistant(id: "msg_a", output: 332, cacheWrite: 100),
        assistant(id: "msg_a", output: 332, cacheWrite: 100),
        assistant(id: "msg_s", model: "<synthetic>", output: 50),
        "not json at all",
    ])
    let index = fixture.index()
    #expect(index.scan())
    let rollup = index.snapshot()
    let sum = totals(rollup)
    #expect(sum.messages == 1)
    #expect(sum.output == 332)
    #expect(sum.input == 10)
    #expect(sum.cacheWrite5m == 100)
    #expect(rollup.models == ["claude-opus-5"])
    #expect(rollup.projects.first?.name == "proj")
    #expect(rollup.projects.first?.nameQuality == 2)
}

@Test func copiesInOtherFilesAndSubagentsAreHandled() throws {
    let fixture = try Fixture()
    try fixture.write("-Users-me-proj/s1.jsonl", [assistant(id: "msg_a", output: 40)])
    // A resumed session repeats the earlier reply; a subagent logs its own.
    try fixture.write("-Users-me-proj/s2.jsonl", [assistant(id: "msg_a", output: 40),
                                                   assistant(id: "msg_b", time: "2026-09-20T10:03:00.000Z", output: 60)])
    try fixture.write("-Users-me-proj/s2/subagents/agent-1.jsonl",
                      [assistant(id: "msg_c", model: "claude-haiku-4-5-20251001", time: "2026-09-20T10:04:00.000Z", output: 9)])
    let index = fixture.index()
    index.scan()
    let rollup = index.snapshot()
    #expect(totals(rollup).messages == 3)
    #expect(totals(rollup).output == 109)
    #expect(rollup.transcriptCount == 3)
    #expect(Set(rollup.models) == ["claude-opus-5", "claude-haiku-4-5-20251001"])
}

@Test func fallbackRepliesBillEveryAttempt() throws {
    let fixture = try Fixture()
    let iterations = #","iterations":[{"type":"message","model":"claude-fable-5","input_tokens":2,"output_tokens":346,"cache_creation_input_tokens":1335,"cache_read_input_tokens":341269},{"type":"fallback_message","model":"claude-opus-4-8","input_tokens":2,"output_tokens":467,"cache_creation_input_tokens":0,"cache_read_input_tokens":241197}]"#
    try fixture.write("-Users-me-proj/s1.jsonl", [
        assistant(id: "msg_f", model: "claude-opus-4-8", input: 2, output: 467, cacheRead: 241197, usageExtra: iterations),
    ])
    let index = fixture.index()
    index.scan()
    let rollup = index.snapshot()
    #expect(tokens(rollup, model: "claude-fable-5") == 2 + 346 + 1335 + 341269)
    #expect(tokens(rollup, model: "claude-opus-4-8") == 2 + 467 + 241197)
}

@Test func splitsCacheWritesAndTracksFastMode() throws {
    let fixture = try Fixture()
    let extra = #","cache_creation":{"ephemeral_1h_input_tokens":300,"ephemeral_5m_input_tokens":100},"speed":"fast""#
    try fixture.write("-Users-me-proj/s1.jsonl", [assistant(id: "msg_x", cacheWrite: 400, usageExtra: extra)])
    let index = fixture.index()
    index.scan()
    let rollup = index.snapshot()
    #expect(rollup.models == ["claude-opus-5#fast"])
    #expect(totals(rollup).cacheWrite1h == 300)
    #expect(totals(rollup).cacheWrite5m == 100)
}

@Test func readsOnlyWhatWasAppended() throws {
    let fixture = try Fixture()
    try fixture.write("-Users-me-proj/s1.jsonl", [assistant(id: "msg_a", output: 5)])
    let index = fixture.index()
    #expect(index.scan())
    #expect(!index.scan())
    try fixture.append("-Users-me-proj/s1.jsonl", [assistant(id: "msg_b", time: "2026-09-20T11:00:00.000Z", output: 6)])
    #expect(index.scan())
    #expect(totals(index.snapshot()).output == 11)
    #expect(!index.scan())
}

@Test func waitsForAnUnfinishedLastLine() throws {
    let fixture = try Fixture()
    let url = try fixture.write("-Users-me-proj/s1.jsonl", [assistant(id: "msg_a", output: 5),
                                                             assistant(id: "msg_b", output: 6)], newlineAtEnd: false)
    let index = fixture.index()
    index.scan()
    #expect(totals(index.snapshot()).messages == 1)
    // Once the file has been quiet for a while, the last line counts.
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: url.path)
    index.scan()
    #expect(totals(index.snapshot()).messages == 2)
}

@Test func historySurvivesDeletedTranscriptsAndRestarts() throws {
    let fixture = try Fixture()
    let url = try fixture.write("-Users-me-proj/s1.jsonl", [
        assistant(id: "msg_a", time: "2026-06-01T10:00:00.000Z", output: 5),
        assistant(id: "msg_b", request: "req_2", time: "2026-09-20T10:00:00.000Z", output: 6),
    ])
    let first = fixture.index()
    first.scan(now: Timestamp.date("2026-09-21T00:00:00Z")!)
    try first.save()

    try FileManager.default.removeItem(at: url)
    let second = fixture.index()
    #expect(totals(second.snapshot()).output == 11)
    second.scan(now: Timestamp.date("2026-09-21T00:00:00Z")!)
    #expect(totals(second.snapshot()).output == 11)
    #expect(second.fileCount == 0)

    // The old reply was settled to just its id; a later copy of it is still skipped.
    try fixture.write("-Users-me-proj/s9.jsonl", [assistant(id: "msg_a", time: "2026-06-01T10:00:00.000Z", output: 5)])
    second.scan(now: Timestamp.date("2026-09-21T00:00:00Z")!)
    #expect(totals(second.snapshot()).output == 11)
}

@Test func stateFileRoundTripsLargeBitPatterns() throws {
    let fixture = try Fixture()
    // 23:27 UTC is minute 1407, the sign bit of word 21. Activity at 23:58 spills into the next day.
    try fixture.write("-Users-me-proj/s1.jsonl", [assistant(id: "msg_a", time: "2026-09-20T23:27:30.000Z"),
                                                   assistant(id: "msg_b", time: "2026-09-20T23:58:30.000Z")])
    let index = fixture.index()
    index.scan()
    try index.save()
    let before = index.snapshot()
    let after = fixture.index().snapshot()
    let key: (UsageRollup.Minutes) -> String = { "\($0.day)/\($0.model)" }
    #expect(Dictionary(uniqueKeysWithValues: before.minutes.map { (key($0), $0.set) })
            == Dictionary(uniqueKeysWithValues: after.minutes.map { (key($0), $0.set) }))
    #expect(after.minutes.reduce(0) { $0 + $1.set.count } == 2 * TranscriptIndex.activityWindowMinutes)
    #expect(Set(after.minutes.map(\.day)).count == 2)
}

@Test func projectNamesComeFromTheWorkingDirectory() {
    #expect(TranscriptIndex.encodeProjectPath("/Users/me/my.app") == "-Users-me-my-app")
    #expect(TranscriptIndex.fallbackName(folder: TranscriptIndex.encodeProjectPath(NSHomeDirectory()) + "-code-site") == "code-site")
    #expect(TranscriptIndex.fallbackName(folder: "") == "Other")
}
