import Foundation

public enum ClaudonInfo {
    public static let version = "1.0.0"
}

/// Token totals for one slice of usage: a message, a quarter hour, a day.
public struct TokenCounts: Hashable, Sendable {
    public var input: Int64
    public var output: Int64
    public var cacheWrite5m: Int64
    public var cacheWrite1h: Int64
    public var cacheRead: Int64
    /// API responses (assistant messages) behind these tokens.
    public var messages: Int64

    public static let zero = TokenCounts()

    public init(input: Int64 = 0, output: Int64 = 0, cacheWrite5m: Int64 = 0,
                cacheWrite1h: Int64 = 0, cacheRead: Int64 = 0, messages: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.messages = messages
    }

    /// Every token the requests touched, cache reads included.
    public var total: Int64 { input + output + cacheWrite5m + cacheWrite1h + cacheRead }

    public var isZero: Bool { self == .zero }

    /// Field-wise maximum. Claude Code logs a streamed reply as several rows that share one
    /// message id, and only the last row carries the final output count.
    public func fieldwiseMax(_ other: TokenCounts) -> TokenCounts {
        TokenCounts(input: max(input, other.input),
                    output: max(output, other.output),
                    cacheWrite5m: max(cacheWrite5m, other.cacheWrite5m),
                    cacheWrite1h: max(cacheWrite1h, other.cacheWrite1h),
                    cacheRead: max(cacheRead, other.cacheRead),
                    messages: max(messages, other.messages))
    }

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input,
                    output: lhs.output + rhs.output,
                    cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
                    cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
                    cacheRead: lhs.cacheRead + rhs.cacheRead,
                    messages: lhs.messages + rhs.messages)
    }

    public static func - (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input - rhs.input,
                    output: lhs.output - rhs.output,
                    cacheWrite5m: lhs.cacheWrite5m - rhs.cacheWrite5m,
                    cacheWrite1h: lhs.cacheWrite1h - rhs.cacheWrite1h,
                    cacheRead: lhs.cacheRead - rhs.cacheRead,
                    messages: lhs.messages - rhs.messages)
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }
}
