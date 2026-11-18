import Foundation

// MARK: - Watch companion payload (daily quote + reading progress)

public enum WatchCompanionLimits {
    /// Contract cap against externally constructed sentences. QuoteExtractor
    /// already selects 40–160 chars; 200 leaves a narrow margin.
    public static let maxSentenceLength = 200
    /// Display-title cap (characters).
    public static let maxTitleLength = 80
    /// Encoded payload cap — same value as WatchSummaryLimits.maxEncodedBytes;
    /// both keys together stay ≤16 KiB inside the ~64 KiB context budget.
    public static let maxEncodedBytes = 8 * 1024
    /// Daily-content staleness TTL (a quote is a day-scale datum).
    public static let defaultMaxAge: TimeInterval = 24 * 60 * 60
    /// Page-turn push throttle.
    public static let pushThrottleInterval: TimeInterval = 60
}

public struct WatchDailyQuote: Codable, Equatable {
    public var sentence: String
    public var bookTitle: String
    public var bookFileName: String
    /// Physical page, 1-based (see docs/PAGE-BASIS.md).
    public var physicalPage: Int
    /// Local calendar day, yyyy-MM-dd (same format as the macOS app's
    /// quoteDateString — same extractor, same day, same string).
    public var date: String

    public init(sentence: String, bookTitle: String, bookFileName: String,
                physicalPage: Int, date: String) {
        self.sentence = sentence
        self.bookTitle = bookTitle
        self.bookFileName = bookFileName
        self.physicalPage = physicalPage
        self.date = date
    }
}

public struct WatchReadingProgress: Codable, Equatable {
    public var bookTitle: String
    public var bookFileName: String
    /// Physical page, 1-based.
    public var page: Int
    public var pageCount: Int
    public var updatedAt: Date

    public init(bookTitle: String, bookFileName: String, page: Int,
                pageCount: Int, updatedAt: Date) {
        self.bookTitle = bookTitle
        self.bookFileName = bookFileName
        self.page = page
        self.pageCount = pageCount
        self.updatedAt = updatedAt
    }
}

public struct WatchCompanionPayload: Codable, Equatable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var pushedAt: Date
    public var dailyQuote: WatchDailyQuote?
    public var progress: WatchReadingProgress?
    /// True when any field was shortened to fit the contract caps.
    public var truncated: Bool

    /// Both parts nil is an EMPTY payload — rejected here (and therefore also
    /// unencodable via WatchCompanionCodec, which goes through a decoded
    /// value) so a pointless push can never overwrite a good cached one.
    public init(pushedAt: Date, dailyQuote: WatchDailyQuote?,
                progress: WatchReadingProgress?, truncated: Bool) throws {
        guard dailyQuote != nil || progress != nil else {
            throw WatchCompanionError.emptyPayload
        }
        self.schemaVersion = Self.schemaVersion
        self.pushedAt = pushedAt
        self.dailyQuote = dailyQuote
        self.progress = progress
        self.truncated = truncated
    }

    public func isExpired(now: Date = Date(),
                          maxAge: TimeInterval = WatchCompanionLimits.defaultMaxAge) -> Bool {
        now.timeIntervalSince(pushedAt) > maxAge
    }
}

/// Companion payload errors — deliberately SEPARATE from WatchSummaryError so
/// each payload evolves its own contract without coupling (same reasoning as
/// WatchSummaryError vs SyncError).
public enum WatchCompanionError: Error, CustomStringConvertible {
    case payloadTooLarge(bytes: Int, cap: Int)
    case emptyPayload
    case unsupportedSchemaVersion(Int)

    public var description: String {
        switch self {
        case .payloadTooLarge(let bytes, let cap):
            return "watch companion \(bytes) bytes exceeds cap \(cap) bytes"
        case .emptyPayload:
            return "watch companion payload is empty"
        case .unsupportedSchemaVersion(let v):
            return "watch companion schema v\(v) not supported (expected v\(WatchCompanionPayload.schemaVersion))"
        }
    }
}

public enum WatchCompanionCodec {
    public static func encode(_ payload: WatchCompanionPayload) throws -> Data {
        let data = try JSONEncoder().encode(payload)
        guard data.count <= WatchCompanionLimits.maxEncodedBytes else {
            throw WatchCompanionError.payloadTooLarge(bytes: data.count, cap: WatchCompanionLimits.maxEncodedBytes)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> WatchCompanionPayload {
        guard !data.isEmpty else { throw WatchCompanionError.emptyPayload }
        let payload = try JSONDecoder().decode(WatchCompanionPayload.self, from: data)
        guard payload.schemaVersion == WatchCompanionPayload.schemaVersion else {
            throw WatchCompanionError.unsupportedSchemaVersion(payload.schemaVersion)
        }
        return payload
    }
}

// MARK: - Contract helpers (pure Foundation; shared by iPhone bridge, watch
// shell and the synthetic tests)

public enum WatchCompanion {
    /// Companion key in the application context. Single point shared by the
    /// iPhone bridge and the watch shell (the summary key keeps its existing
    /// per-side literals — untouched).
    public static let contextKey = "watch-companion-v1"

    /// THE merge point for the single-slot applicationContext: builds the
    /// dictionary that carries BOTH payloads in ONE update. Callers pass
    /// their own key names; Core never hardcodes the summary key.
    /// Both values nil → emptyPayload (nothing to push, never a wipe).
    public static func makeContext(summaryKey: String, summary: Data?,
                                   companionKey: String, companion: Data?) throws -> [String: Data] {
        guard summary != nil || companion != nil else {
            throw WatchCompanionError.emptyPayload
        }
        var context: [String: Data] = [:]
        if let summary { context[summaryKey] = summary }
        if let companion { context[companionKey] = companion }
        return context
    }

    /// Receiver-side key dispatch reads each payload key independently, so a
    /// companion-only context is never dropped because the summary key is
    /// absent. The watch shell feeds every received context through this
    /// instead of guarding on one key first.
    public static func splitContext(_ context: [String: Any], summaryKey: String,
                                    companionKey: String) -> (summary: Data?, companion: Data?) {
        let summary = context[summaryKey] as? Data
        let companion = context[companionKey] as? Data
        return (summary, companion)
    }

    /// Daily-quote repick gate: no cache, or cache from another day → repick.
    public static func needsRepick(cachedDate: String?, today: String) -> Bool {
        guard let cachedDate else { return true }
        return cachedDate != today
    }

    /// Push throttle: first push always allowed; afterwards at most one per
    /// interval (page-turn pushes only — explicit events, no polling).
    public static func shouldPush(lastPush: Date?, now: Date) -> Bool {
        guard let lastPush else { return true }
        return now.timeIntervalSince(lastPush) >= WatchCompanionLimits.pushThrottleInterval
    }

    /// Local day string, yyyy-MM-dd (en_US_POSIX formatter, current calendar
    /// — same construction as the macOS app's quoteDateString, so the same
    /// index yields the same date string on both sides).
    public static func dateString(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar.current
        return formatter.string(from: date)
    }

    /// UserDefaults key for the iPhone-side daily-quote cache (value = the
    /// encoded WatchDailyQuote JSON; the day is part of the key).
    public static func dailyQuoteCacheKey(_ date: Date = Date()) -> String {
        "watch.dailyQuote." + dateString(date)
    }

    /// Title cap: shorten to maxTitleLength and report the truncation.
    public static func cappedTitle(_ title: String) -> (text: String, truncated: Bool) {
        guard title.count > WatchCompanionLimits.maxTitleLength else { return (title, false) }
        return (String(title.prefix(WatchCompanionLimits.maxTitleLength)), true)
    }

    /// Sentence cap: shorten to maxSentenceLength and report the truncation.
    public static func cappedSentence(_ sentence: String) -> (text: String, truncated: Bool) {
        guard sentence.count > WatchCompanionLimits.maxSentenceLength else { return (sentence, false) }
        return (String(sentence.prefix(WatchCompanionLimits.maxSentenceLength)), true)
    }

    /// Builder used by the iPhone side: applies the contract caps, merges the
    /// truncation flags and rejects an all-empty payload. (Direct
    /// WatchCompanionPayload init stays uncapped on purpose — the codec size
    /// gate is the hard wall; caps here are the tidy-up pass.)
    public static func build(pushedAt: Date, dailyQuote: WatchDailyQuote?,
                             progress: WatchReadingProgress?) throws -> WatchCompanionPayload {
        guard dailyQuote != nil || progress != nil else {
            throw WatchCompanionError.emptyPayload
        }
        var truncated = false
        var quote = dailyQuote
        if var q = quote {
            let (title, titleCut) = cappedTitle(q.bookTitle)
            let (sentence, sentenceCut) = cappedSentence(q.sentence)
            if titleCut || sentenceCut {
                q.bookTitle = title
                q.sentence = sentence
                quote = q
                truncated = true
            }
        }
        var prog = progress
        if var p = prog {
            let (title, titleCut) = cappedTitle(p.bookTitle)
            if titleCut {
                p.bookTitle = title
                prog = p
                truncated = true
            }
        }
        return try WatchCompanionPayload(pushedAt: pushedAt, dailyQuote: quote,
                                         progress: prog, truncated: truncated)
    }
}
