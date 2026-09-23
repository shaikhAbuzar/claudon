import Foundation

/// Reads Claude Code transcripts (`~/.claude/projects/**/*.jsonl`) incrementally and keeps
/// token totals per quarter hour, model and project, plus the minutes Claude was active.
///
/// Totals live in Claudon's own state file, so history stays after Claude Code deletes old
/// transcripts. Not thread-safe: use one instance from one serial queue.
public final class TranscriptIndex {
    /// Minutes of activity one logged reply stands for, like an idle timeout: replies less
    /// than this far apart count as continuous use.
    public static let activityWindowMinutes = 5

    /// The rows of one message arrive within seconds. After this many days only the message
    /// id is kept, which is enough to skip copies that resumed sessions write again.
    static let settleDays = 3

    public static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".claude/projects", isDirectory: true),
                home.appendingPathComponent(".config/claude/projects", isDirectory: true)]
    }

    public let roots: [URL]
    private let stateURL: URL?
    private var state = IndexState()
    private var loaded = false
    private var unsaved = false
    private var modelLookup: [String: Int32] = [:]
    private var projectLookup: [String: Int32] = [:]
    private let decoder = JSONDecoder()

    public init(roots: [URL] = TranscriptIndex.defaultRoots, stateURL: URL?) {
        self.roots = roots
        self.stateURL = stateURL
    }

    public var fileCount: Int {
        ensureLoaded()
        return state.files.count
    }

    /// Reads whatever was appended since the last scan. Returns true if any total changed.
    @discardableResult
    public func scan(now: Date = Date()) -> Bool {
        ensureLoaded()
        let fm = FileManager.default
        var changed = false
        var present = Set<String>()
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let path = url.path
                guard let attributes = try? fm.attributesOfItem(atPath: path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = (attributes[.size] as? NSNumber)?.uint64Value else { continue }
                present.insert(path)
                let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                var mark = state.files[path] ?? FileMark(offset: 0, size: 0, mtime: 0, inode: inode)
                if mark.inode != inode || size < mark.offset {
                    // Replaced or rewritten: read it again; message ids keep totals from doubling.
                    mark = FileMark(offset: 0, size: 0, mtime: 0, inode: inode)
                }
                guard size != mark.size || mtime != mark.mtime else { continue }
                let folder = Self.projectFolder(of: url, under: root)
                if read(url, folder: folder, mark: &mark, mtime: mtime, now: now) { changed = true }
                mark.size = size
                mark.mtime = mtime
                state.files[path] = mark
                unsaved = true
            }
        }
        let gone = state.files.keys.filter { !present.contains($0) }
        for path in gone { state.files[path] = nil }
        if !gone.isEmpty { unsaved = true }
        settle(now: now)
        if changed { unsaved = true }
        return changed
    }

    public func snapshot() -> UsageRollup {
        ensureLoaded()
        return UsageRollup(
            models: state.models,
            projects: state.projects,
            buckets: state.buckets.map { UsageRollup.Bucket(key: $0.key, counts: $0.value) },
            minutes: state.minutes.map { UsageRollup.Minutes(day: $0.key.day, model: $0.key.model, set: $0.value) },
            lastActivity: state.lastActivity.map { Date(timeIntervalSince1970: $0) },
            transcriptCount: state.files.count)
    }

    /// Writes the state file if anything changed since the last save.
    public func save() throws {
        guard let stateURL, loaded, unsaved else { return }
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(StoredState(state))
        try data.write(to: stateURL, options: .atomic)
        unsaved = false
    }

    // MARK: Reading

    private func read(_ url: URL, folder: String, mark: inout FileMark, mtime: Double, now: Date) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: mark.offset)) != nil else { return false }
        var changed = false
        var offset = mark.offset
        var pending = Data()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            pending.append(chunk)
            let consumed = pending.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                var start = 0
                while start < buffer.count, let newline = memchr(base + start, 0x0A, buffer.count - start) {
                    let end = base.distance(to: UnsafeRawPointer(newline))
                    if end > start, ingest(line: UnsafeRawBufferPointer(start: base + start, count: end - start),
                                           folder: folder) {
                        changed = true
                    }
                    start = end + 1
                }
                return start
            }
            if consumed > 0 {
                pending = consumed == pending.count ? Data() : Data(pending.dropFirst(consumed))
                offset += UInt64(consumed)
            }
        }
        // A last line without a newline is read once the file has been quiet for a while.
        if !pending.isEmpty, now.timeIntervalSince1970 - mtime > 600 {
            if pending.withUnsafeBytes({ ingest(line: $0, folder: folder) }) { changed = true }
            offset += UInt64(pending.count)
        }
        mark.offset = offset
        return changed
    }

    private static let assistantMarker = Array(#""type":"assistant""#.utf8)

    private func ingest(line: UnsafeRawBufferPointer, folder: String) -> Bool {
        guard let base = line.baseAddress, line.count > Self.assistantMarker.count else { return false }
        // Only assistant rows carry usage; skip everything else without parsing it.
        let isAssistant = Self.assistantMarker.withUnsafeBytes { marker in
            memmem(base, line.count, marker.baseAddress, marker.count) != nil
        }
        guard isAssistant else { return false }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        guard let row = try? decoder.decode(RawLine.self, from: data), row.type == "assistant" else { return false }
        return record(row, folder: folder)
    }

    private func record(_ row: RawLine, folder: String) -> Bool {
        guard let message = row.message, let usage = message.usage,
              let model = message.model, !model.isEmpty, !model.hasPrefix("<"),
              let stamp = row.timestamp.flatMap(Timestamp.parse) else { return false }
        let parts = Self.parts(of: usage, model: model)
        guard !parts.isEmpty else { return false }
        let project = projectIndex(folder: folder, cwd: row.cwd)
        var changed = false

        let minute = Int((stamp / 60).rounded(.down))
        let indexed = parts.map { (model: modelIndex($0.0), counts: $0.1) }
        for part in indexed where markActive(minute: minute, model: part.model) {
            changed = true
        }
        if stamp > (state.lastActivity ?? 0) { state.lastActivity = stamp }

        guard let id = message.id, !id.isEmpty else { return changed }
        let key = Self.messageKey(id: id, requestId: row.requestId)
        guard !state.settled.contains(key) else { return changed }
        var seen = state.recent[key]
            ?? SeenMessage(quarter: Int32((stamp / 900).rounded(.down)), project: project, parts: [:])
        for part in indexed {
            let before = seen.parts[part.model] ?? .zero
            var after = before.fieldwiseMax(part.counts)
            after.messages = 1
            let delta = after - before
            guard !delta.isZero else { continue }
            let bucket = BucketKey(quarter: seen.quarter, model: part.model, project: seen.project)
            state.buckets[bucket, default: .zero] += delta
            seen.parts[part.model] = after
            changed = true
        }
        state.recent[key] = seen
        return changed
    }

    /// Token counts per model for one logged reply.
    static func parts(of usage: RawUsage, model: String) -> [(String, TokenCounts)] {
        var totals: [String: TokenCounts] = [:]
        var order: [String] = []
        func add(_ model: String, _ counts: TokenCounts) {
            guard counts.total > 0 else { return }
            let key = ModelCatalog.key(model: model, speed: usage.speed)
            if totals[key] == nil { order.append(key) }
            totals[key, default: .zero] += counts
        }
        if let iterations = usage.iterations, iterations.count > 1 {
            // A server-side fallback bills every attempt, but top-level usage holds only the last.
            for step in iterations {
                let stepModel = step.model.flatMap { $0.isEmpty ? nil : $0 } ?? model
                add(stepModel, counts(input: step.inputTokens, output: step.outputTokens,
                                      cacheCreation: step.cacheCreationInputTokens,
                                      cacheRead: step.cacheReadInputTokens, breakdown: step.cacheCreation))
            }
        } else {
            add(model, counts(input: usage.inputTokens, output: usage.outputTokens,
                              cacheCreation: usage.cacheCreationInputTokens,
                              cacheRead: usage.cacheReadInputTokens, breakdown: usage.cacheCreation))
        }
        return order.map { ($0, totals[$0]!) }
    }

    static func counts(input: Int64?, output: Int64?, cacheCreation: Int64?, cacheRead: Int64?,
                       breakdown: RawCacheCreation?) -> TokenCounts {
        let writes = max(0, cacheCreation ?? 0)
        let hourWrites = min(writes, max(0, breakdown?.ephemeral1h ?? 0))
        return TokenCounts(input: max(0, input ?? 0), output: max(0, output ?? 0),
                           cacheWrite5m: writes - hourWrites, cacheWrite1h: hourWrites,
                           cacheRead: max(0, cacheRead ?? 0), messages: 1)
    }

    private func markActive(minute: Int, model: Int32) -> Bool {
        var changed = false
        for m in minute ..< minute + Self.activityWindowMinutes {
            let day = Self.floorDiv(m, 1440)
            let key = MinuteKey(day: Int32(day), model: model)
            if state.minutes[key, default: MinuteSet()].insert(m - day * 1440) { changed = true }
        }
        return changed
    }

    private func settle(now: Date) {
        let cutoff = Int32((now.timeIntervalSince1970 / 900).rounded(.down)) - Int32(Self.settleDays * 96)
        let old = state.recent.filter { $0.value.quarter < cutoff }.map(\.key)
        guard !old.isEmpty else { return }
        for key in old {
            state.recent[key] = nil
            state.settled.insert(key)
        }
        unsaved = true
    }

    // MARK: Names

    private func modelIndex(_ key: String) -> Int32 {
        if let known = modelLookup[key] { return known }
        let index = Int32(state.models.count)
        state.models.append(key)
        modelLookup[key] = index
        return index
    }

    private func projectIndex(folder: String, cwd: String?) -> Int32 {
        let index: Int32
        if let known = projectLookup[folder] {
            index = known
        } else {
            index = Int32(state.projects.count)
            state.projects.append(ProjectInfo(folder: folder, name: Self.fallbackName(folder: folder), nameQuality: 0))
            projectLookup[folder] = index
        }
        let i = Int(index)
        if state.projects[i].nameQuality < 2, let cwd, !cwd.isEmpty {
            let quality = Self.encodeProjectPath(cwd) == folder ? 2 : 1
            if quality > state.projects[i].nameQuality {
                let leaf = (cwd as NSString).lastPathComponent
                state.projects[i].name = leaf.isEmpty ? cwd : leaf
                state.projects[i].nameQuality = quality
            }
        }
        return index
    }

    /// Claude Code names a project's folder after its path, with every character other than
    /// ASCII letters and digits replaced by "-".
    static func encodeProjectPath(_ path: String) -> String {
        String(path.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return Character(scalar)
            default: return "-"
            }
        })
    }

    static func fallbackName(folder: String) -> String {
        guard !folder.isEmpty else { return "Other" }
        let home = encodeProjectPath(NSHomeDirectory())
        if folder == home { return "~" }
        var name = folder
        if name.hasPrefix(home + "-") { name.removeFirst(home.count + 1) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty ? folder : name
    }

    static func projectFolder(of file: URL, under root: URL) -> String {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = file.standardizedFileURL.pathComponents
        guard parts.count > rootParts.count + 1, Array(parts.prefix(rootParts.count)) == rootParts else { return "" }
        return parts[rootParts.count]
    }

    /// 64-bit FNV-1a of the message and request ids.
    static func messageKey(id: String, requestId: String?) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        hash = (hash ^ 0x3A) &* 0x100_0000_01b3
        for byte in (requestId ?? "").utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return Int64(bitPattern: hash)
    }

    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }

    // MARK: Persistence

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let stateURL, let stored = Self.load(stateURL) { state = stored }
        modelLookup = Dictionary(state.models.enumerated().map { ($0.element, Int32($0.offset)) },
                                 uniquingKeysWith: { first, _ in first })
        projectLookup = Dictionary(state.projects.enumerated().map { ($0.element.folder, Int32($0.offset)) },
                                   uniquingKeysWith: { first, _ in first })
    }

    static func load(_ url: URL) -> IndexState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let stored = try? JSONDecoder().decode(StoredState.self, from: data),
           stored.version == StoredState.currentVersion {
            return IndexState(stored)
        }
        // Keep an unreadable file for inspection rather than overwriting the history in it.
        let aside = url.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return nil
    }
}

/// The app hands the index to one serial queue and only touches it there.
extension TranscriptIndex: @unchecked Sendable {}

// MARK: - Transcript rows

/// The fields Claudon needs from a transcript row. Every field is optional and decoded
/// leniently, so an unexpected value in one field doesn't lose the row.
struct RawLine: Decodable {
    var type: String?
    var timestamp: String?
    var requestId: String?
    var cwd: String?
    var message: RawMessage?

    enum CodingKeys: String, CodingKey { case type, timestamp, requestId, cwd, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
        requestId = try? c.decodeIfPresent(String.self, forKey: .requestId)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        message = try? c.decodeIfPresent(RawMessage.self, forKey: .message)
    }
}

struct RawMessage: Decodable {
    var id: String?
    var model: String?
    var usage: RawUsage?

    enum CodingKeys: String, CodingKey { case id, model, usage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        usage = try? c.decodeIfPresent(RawUsage.self, forKey: .usage)
    }
}

struct RawUsage: Decodable {
    var inputTokens: Int64?
    var outputTokens: Int64?
    var cacheCreationInputTokens: Int64?
    var cacheReadInputTokens: Int64?
    var cacheCreation: RawCacheCreation?
    var speed: String?
    var iterations: [RawIteration]?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreation = "cache_creation"
        case speed, iterations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try? c.decodeIfPresent(Int64.self, forKey: .inputTokens)
        outputTokens = try? c.decodeIfPresent(Int64.self, forKey: .outputTokens)
        cacheCreationInputTokens = try? c.decodeIfPresent(Int64.self, forKey: .cacheCreationInputTokens)
        cacheReadInputTokens = try? c.decodeIfPresent(Int64.self, forKey: .cacheReadInputTokens)
        cacheCreation = try? c.decodeIfPresent(RawCacheCreation.self, forKey: .cacheCreation)
        speed = try? c.decodeIfPresent(String.self, forKey: .speed)
        iterations = try? c.decodeIfPresent([RawIteration].self, forKey: .iterations)
    }
}

struct RawIteration: Decodable {
    var model: String?
    var inputTokens: Int64?
    var outputTokens: Int64?
    var cacheCreationInputTokens: Int64?
    var cacheReadInputTokens: Int64?
    var cacheCreation: RawCacheCreation?

    enum CodingKeys: String, CodingKey {
        case model
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreation = "cache_creation"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        inputTokens = try? c.decodeIfPresent(Int64.self, forKey: .inputTokens)
        outputTokens = try? c.decodeIfPresent(Int64.self, forKey: .outputTokens)
        cacheCreationInputTokens = try? c.decodeIfPresent(Int64.self, forKey: .cacheCreationInputTokens)
        cacheReadInputTokens = try? c.decodeIfPresent(Int64.self, forKey: .cacheReadInputTokens)
        cacheCreation = try? c.decodeIfPresent(RawCacheCreation.self, forKey: .cacheCreation)
    }
}

struct RawCacheCreation: Decodable {
    var ephemeral1h: Int64?

    enum CodingKeys: String, CodingKey { case ephemeral1h = "ephemeral_1h_input_tokens" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ephemeral1h = try? c.decodeIfPresent(Int64.self, forKey: .ephemeral1h)
    }
}

// MARK: - State

struct FileMark: Codable, Equatable {
    var offset: UInt64
    var size: UInt64
    var mtime: Double
    var inode: UInt64
}

struct MinuteKey: Hashable {
    var day: Int32
    var model: Int32
}

struct SeenMessage {
    var quarter: Int32
    var project: Int32
    /// What has been counted so far for this message, per model.
    var parts: [Int32: TokenCounts]
}

struct IndexState {
    var models: [String] = []
    var projects: [ProjectInfo] = []
    var files: [String: FileMark] = [:]
    var buckets: [BucketKey: TokenCounts] = [:]
    var minutes: [MinuteKey: MinuteSet] = [:]
    var recent: [Int64: SeenMessage] = [:]
    var settled: Set<Int64> = []
    var lastActivity: Double?

    init() {}
}

/// On-disk form of `IndexState`, flattened into arrays to keep the file small.
struct StoredState: Codable {
    static let currentVersion = 1

    var version: Int
    var models: [String]
    var projects: [ProjectInfo]
    var files: [String: FileMark]
    /// [quarter, model, project, input, output, cacheWrite5m, cacheWrite1h, cacheRead, messages]
    var buckets: [[Int64]]
    /// [day, model, then the 23 words of the minute set as bit patterns]
    var minutes: [[Int64]]
    /// [key, quarter, project, then per model: model, input, output, cacheWrite5m, cacheWrite1h, cacheRead, messages]
    var recent: [[Int64]]
    var settled: [Int64]
    var lastActivity: Double?
}

extension StoredState {
    init(_ s: IndexState) {
        version = Self.currentVersion
        models = s.models
        projects = s.projects
        files = s.files
        buckets = s.buckets.map { key, c in
            [Int64(key.quarter), Int64(key.model), Int64(key.project),
             c.input, c.output, c.cacheWrite5m, c.cacheWrite1h, c.cacheRead, c.messages]
        }
        minutes = s.minutes.map { key, set in
            [Int64(key.day), Int64(key.model)] + set.words.map { Int64(bitPattern: $0) }
        }
        recent = s.recent.map { key, seen in
            var row: [Int64] = [key, Int64(seen.quarter), Int64(seen.project)]
            for (model, c) in seen.parts {
                row += [Int64(model), c.input, c.output, c.cacheWrite5m, c.cacheWrite1h, c.cacheRead, c.messages]
            }
            return row
        }
        settled = Array(s.settled)
        lastActivity = s.lastActivity
    }
}

extension IndexState {
    init(_ s: StoredState) {
        self.init()
        models = s.models
        projects = s.projects
        files = s.files
        for r in s.buckets where r.count == 9 {
            let key = BucketKey(quarter: Int32(truncatingIfNeeded: r[0]), model: Int32(truncatingIfNeeded: r[1]),
                                project: Int32(truncatingIfNeeded: r[2]))
            buckets[key] = TokenCounts(input: r[3], output: r[4], cacheWrite5m: r[5], cacheWrite1h: r[6],
                                       cacheRead: r[7], messages: r[8])
        }
        for r in s.minutes where r.count == 2 + MinuteSet.wordCount {
            let key = MinuteKey(day: Int32(truncatingIfNeeded: r[0]), model: Int32(truncatingIfNeeded: r[1]))
            minutes[key] = MinuteSet(words: r.dropFirst(2).map { UInt64(bitPattern: $0) })
        }
        for r in s.recent where r.count >= 3 && (r.count - 3) % 7 == 0 {
            var parts: [Int32: TokenCounts] = [:]
            var i = 3
            while i + 7 <= r.count {
                parts[Int32(truncatingIfNeeded: r[i])] = TokenCounts(
                    input: r[i + 1], output: r[i + 2], cacheWrite5m: r[i + 3], cacheWrite1h: r[i + 4],
                    cacheRead: r[i + 5], messages: r[i + 6])
                i += 7
            }
            recent[r[0]] = SeenMessage(quarter: Int32(truncatingIfNeeded: r[1]),
                                       project: Int32(truncatingIfNeeded: r[2]), parts: parts)
        }
        settled = Set(s.settled)
        lastActivity = s.lastActivity
    }
}
