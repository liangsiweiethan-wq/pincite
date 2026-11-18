import Foundation
import CryptoKit

// MARK: - Watch summary (the ONLY payload that crosses to the watch)
//
// Personal-team constraints: the watch is a READ-ONLY summary surface. It
// never receives page text, never receives paths, never searches. The payload
// is aggressively truncated so it always fits a WatchConnectivity
// application-context / userinfo transfer with wide margin.
//
// Freshness: the summary carries `indexStamp` — a deterministic digest over
// the coverage counters and history it was built from — and `generatedAt`.
// A receiver treats the summary as STALE when either the age exceeds the TTL
// or its stamp does not match the stamp it can derive itself (expired
// fingerprint). Stale summaries are still shown, but labelled stale.

public enum WatchSummaryLimits {
    /// Newest queries carried to the watch.
    public static let maxQueries = 3
    /// Per-query display length cap (characters).
    public static let maxQueryLength = 40
    /// Encoded payload cap — comfortably inside WatchConnectivity's
    /// practical userinfo limits (~64 KiB).
    public static let maxEncodedBytes = 8 * 1024
    /// Default staleness TTL.
    public static let defaultMaxAge: TimeInterval = 6 * 60 * 60 // 6h
}

public struct WatchSummary: Codable, Equatable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var generatedAt: Date
    /// Deterministic digest over coverage+history at generation time.
    public var indexStamp: String
    public var bookCount: Int
    public var pageCount: Int
    public var pagesWithoutText: Int
    public var errorBooks: Int
    public var historyCount: Int
    /// Newest-first, already truncated to the caps.
    public var queries: [String]
    /// True when any query/history entry was dropped or shortened.
    public var truncated: Bool

    public init(generatedAt: Date, indexStamp: String, bookCount: Int, pageCount: Int,
                pagesWithoutText: Int, errorBooks: Int, historyCount: Int,
                queries: [String], truncated: Bool) {
        self.schemaVersion = Self.schemaVersion
        self.generatedAt = generatedAt
        self.indexStamp = indexStamp
        self.bookCount = bookCount
        self.pageCount = pageCount
        self.pagesWithoutText = pagesWithoutText
        self.errorBooks = errorBooks
        self.historyCount = historyCount
        self.queries = queries
        self.truncated = truncated
    }

    public func isExpired(now: Date = Date(), maxAge: TimeInterval = WatchSummaryLimits.defaultMaxAge) -> Bool {
        now.timeIntervalSince(generatedAt) > maxAge
    }

    /// Expired-fingerprint check: a summary whose stamp does not match the
    /// current stamp describes an index state that no longer exists.
    public func stampMatches(currentStamp: String) -> Bool {
        indexStamp == currentStamp
    }
}

/// Watch payload errors — deliberately SEPARATE from SyncError so the watch
/// target needs no dependency on the sync snapshot model.
public enum WatchSummaryError: Error, CustomStringConvertible {
    case payloadTooLarge(bytes: Int, cap: Int)
    case emptyPayload
    case unsupportedSchemaVersion(Int)

    public var description: String {
        switch self {
        case .payloadTooLarge(let bytes, let cap):
            return "watch summary \(bytes) bytes exceeds cap \(cap) bytes"
        case .emptyPayload:
            return "watch summary payload is empty"
        case .unsupportedSchemaVersion(let v):
            return "watch summary schema v\(v) not supported (expected v\(WatchSummary.schemaVersion))"
        }
    }
}

public enum WatchSummaryCodec {
    public static func encode(_ summary: WatchSummary) throws -> Data {
        let data = try JSONEncoder().encode(summary)
        guard data.count <= WatchSummaryLimits.maxEncodedBytes else {
            throw WatchSummaryError.payloadTooLarge(bytes: data.count, cap: WatchSummaryLimits.maxEncodedBytes)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> WatchSummary {
        guard !data.isEmpty else { throw WatchSummaryError.emptyPayload }
        let summary = try JSONDecoder().decode(WatchSummary.self, from: data)
        guard summary.schemaVersion == WatchSummary.schemaVersion else {
            throw WatchSummaryError.unsupportedSchemaVersion(summary.schemaVersion)
        }
        return summary
    }
}

public enum WatchSummaryBuilder {
    /// Truncation is part of the contract: only the newest
    /// `maxQueries` queries are carried, each shortened to `maxQueryLength`.
    public static func truncate(queries: [String], historyCount: Int) -> (queries: [String], truncated: Bool) {
        var truncated = historyCount > WatchSummaryLimits.maxQueries
        var out: [String] = []
        for query in queries.prefix(WatchSummaryLimits.maxQueries) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.count > WatchSummaryLimits.maxQueryLength {
                out.append(String(trimmed.prefix(WatchSummaryLimits.maxQueryLength)))
                truncated = true
            } else {
                out.append(trimmed)
            }
        }
        if out.count < min(queries.count, WatchSummaryLimits.maxQueries) { truncated = true }
        return (out, truncated)
    }

    public static func build(coverage: CoverageSnapshot?, history: [HistoryEntry],
                             now: Date = Date()) -> WatchSummary {
        let historyCount = history.count
        let (queries, truncatedQueries) = truncate(queries: history.map(\.query), historyCount: historyCount)
        var coverage = coverage
        // The summary must never surface a single root's name across devices.
        coverage?.rootName = nil
        let stamp = indexStamp(coverage: coverage, history: history)
        return WatchSummary(generatedAt: now, indexStamp: stamp,
                            bookCount: coverage?.bookCount ?? 0,
                            pageCount: coverage?.pageCount ?? 0,
                            pagesWithoutText: coverage?.pagesWithoutText ?? 0,
                            errorBooks: coverage?.errorBooks ?? 0,
                            historyCount: historyCount,
                            queries: queries,
                            truncated: truncatedQueries)
    }

    /// Deterministic fingerprint over exactly the fields the summary carries
    /// (counters + queries). Two devices deriving it from the same state get
    /// the same digest — a mismatch means the state moved.
    public static func indexStamp(coverage: CoverageSnapshot?, history: [HistoryEntry]) -> String {
        var canonical = ""
        canonical += "books:\(coverage?.bookCount ?? -1);"
        canonical += "pages:\(coverage?.pageCount ?? -1);"
        canonical += "noText:\(coverage?.pagesWithoutText ?? -1);"
        canonical += "errors:\(coverage?.errorBooks ?? -1);"
        canonical += "lastIndexed:\(coverage?.lastIndexedAt.map { Int($0.timeIntervalSince1970) } ?? -1);"
        for entry in history {
            canonical += "q:\(entry.query)|h:\(entry.hitCount)|t:\(Int(entry.at.timeIntervalSince1970));"
        }
        return "ws1-" + Fingerprint.sha256Hex(of: Data(canonical.utf8))
    }
}
