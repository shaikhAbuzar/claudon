import Foundation

/// API list prices in USD per million tokens.
public struct ModelPrice: Hashable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cacheRead: Double

    public init(input: Double, output: Double, cacheWrite5m: Double, cacheWrite1h: Double, cacheRead: Double) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
    }

    /// Standard cache pricing: writes cost 1.25x (5 minute) or 2x (1 hour) the input price,
    /// reads cost `readMultiplier` times it.
    static func base(_ input: Double, _ output: Double, readMultiplier: Double = 0.1) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheWrite5m: input * 1.25,
                   cacheWrite1h: input * 2, cacheRead: input * readMultiplier)
    }

    func scaled(by factor: Double) -> ModelPrice {
        ModelPrice(input: input * factor, output: output * factor, cacheWrite5m: cacheWrite5m * factor,
                   cacheWrite1h: cacheWrite1h * factor, cacheRead: cacheRead * factor)
    }

    /// Cost in USD of `tokens` at these prices.
    public func cost(of tokens: TokenCounts) -> Double {
        let perMillion = Double(tokens.input) * input
            + Double(tokens.output) * output
            + Double(tokens.cacheWrite5m) * cacheWrite5m
            + Double(tokens.cacheWrite1h) * cacheWrite1h
            + Double(tokens.cacheRead) * cacheRead
        return perMillion / 1_000_000
    }
}

public struct ModelInfo: Hashable, Sendable {
    /// The key Claudon stores: the model id as logged, plus `#fast` for fast mode.
    public var key: String
    public var family: String?
    public var version: String?
    public var isFast: Bool
    /// "Opus 4.8", or "Opus 4.8 (fast)".
    public var displayName: String
    public var price: ModelPrice?
}

public enum ModelCatalog {
    static let fastSuffix = "#fast"

    /// Storage key for a logged model id and its `usage.speed` value.
    public static func key(model: String, speed: String?) -> String {
        speed == "fast" ? model + fastSuffix : model
    }

    public static func info(for key: String) -> ModelInfo {
        let isFast = key.hasSuffix(fastSuffix)
        let raw = isFast ? String(key.dropLast(fastSuffix.count)) : key
        let (family, version) = parse(raw)
        var name = raw
        if let family {
            name = family.prefix(1).uppercased() + family.dropFirst()
            if let version { name += " " + version }
        }
        if isFast { name += " (fast)" }
        return ModelInfo(key: key, family: family, version: version, isFast: isFast,
                         displayName: name, price: price(family: family, version: version, fast: isFast))
    }

    /// Splits ids such as "claude-opus-4-8", "claude-3-5-sonnet-20241022" or
    /// "us.anthropic.claude-haiku-4-5-20251001-v1:0" into a family and a version.
    static func parse(_ raw: String) -> (family: String?, version: String?) {
        var id = raw.lowercased()
        for marker: Character in ["[", "@", ":"] {
            if let cut = id.firstIndex(of: marker) { id = String(id[..<cut]) }
        }
        guard let prefix = id.range(of: "claude-") else { return (nil, nil) }
        id = String(id[prefix.upperBound...])
        var family: String?
        var numbers: [String] = []
        for token in id.split(separator: "-") {
            if token.allSatisfy(\.isNumber) {
                // Runs longer than two digits are release dates, not versions.
                if token.count <= 2 { numbers.append(String(token)) }
            } else if family == nil, token.allSatisfy(\.isLetter) {
                family = String(token)
            }
        }
        guard let family else { return (nil, nil) }
        return (family, numbers.isEmpty ? nil : numbers.joined(separator: "."))
    }

    /// USD per million tokens, from platform.claude.com/docs/en/about-claude/pricing (read 2026-09-23).
    static let listPrices: [String: ModelPrice] = [
        "fable 5.1": .base(10, 50, readMultiplier: 0.025),
        "fable 5": .base(10, 50),
        "mythos 5.1": .base(10, 50, readMultiplier: 0.025),
        "mythos 5": .base(10, 50),
        "opus 5.5": .base(4, 20, readMultiplier: 0.05),
        "opus 5": .base(5, 25),
        "opus 4.8": .base(5, 25),
        "opus 4.7": .base(5, 25),
        "opus 4.6": .base(5, 25),
        "opus 4.5": .base(5, 25),
        "opus 4.1": .base(15, 75),
        "opus 4": .base(15, 75),
        "opus 3": .base(15, 75),
        "sonnet 5": .base(2, 10),
        "sonnet 4.6": .base(3, 15),
        "sonnet 4.5": .base(3, 15),
        "sonnet 4": .base(3, 15),
        "sonnet 3.7": .base(3, 15),
        "sonnet 3.5": .base(3, 15),
        "haiku 4.5": .base(1, 5),
        "haiku 3.5": .base(0.8, 4),
        "haiku 3": ModelPrice(input: 0.25, output: 1.25, cacheWrite5m: 0.30, cacheWrite1h: 0.50, cacheRead: 0.03),
    ]

    /// Fast mode bills twice the standard rates; the cache multipliers apply on top.
    static let fastModeModels: Set<String> = ["opus 5.5", "opus 5", "opus 4.8"]

    /// Versions newer than this table are estimated at the newest known price of their family.
    static let newestInFamily: [String: String] = [
        "fable": "fable 5.1", "mythos": "mythos 5.1", "opus": "opus 5.5", "sonnet": "sonnet 5", "haiku": "haiku 4.5",
    ]

    static func price(family: String?, version: String?, fast: Bool) -> ModelPrice? {
        guard let family else { return nil }
        var key = version.map { "\(family) \($0)" }
        if key.map({ listPrices[$0] == nil }) ?? true { key = newestInFamily[family] }
        guard let key, let base = listPrices[key] else { return nil }
        return fast && fastModeModels.contains(key) ? base.scaled(by: 2) : base
    }
}
