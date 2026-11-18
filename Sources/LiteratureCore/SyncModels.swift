import Foundation

// MARK: - Versioned sync snapshot (cross-device surface)
//
// The ONLY data shape that leaves a device (macOS export / iOS import /
// Watch summary carrier). The whitelist below is the security contract:
//
//   INCLUDED (whitelist): book id, file NAME, metadata (title/author/version/
//   language), page count, index status + timestamps, per-book coverage
//   category, aggregate coverage counters, search-query history.
//
//   EXCLUDED BY DESIGN (never encoded, never decoded):
//     - absolute/relative paths and roots (realPath / rootPath / relPath)
//     - content fingerprints (they are file-bound; another device cannot
//       verify them, and they must not become a tracking surface)
//     - full text of any page, snippets, error message bodies
//     - AI configuration: service URL, model name, API key
//
// Enforcement is structural: `SyncBook.encode(to:)` writes ONLY whitelisted
// keys, so a path or key cannot appear in the payload even if a caller
// constructs a BookRow full of them. Decoding ignores unknown keys and is
// fail-closed on unknown schema versions.

public enum SyncSchema {
    /// The only schema version produced by this build.
    public static let current = 1
    public static let decodable: Set<Int> = [1]
    /// Hard cap for an encoded snapshot (4 MiB) — snapshots are metadata only;
    /// anything larger means a producer is smuggling content.
    public static let maxEncodedBytes = 4 * 1024 * 1024
}

public enum SyncError: Error, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case payloadTooLarge(bytes: Int, cap: Int)
    case emptyPayload

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let v):
            return "sync snapshot schema v\(v) not supported (this build decodes \(SyncSchema.decodable.sorted().map(String.init).joined(separator: ", ")))"
        case .payloadTooLarge(let bytes, let cap):
            return "sync snapshot \(bytes) bytes exceeds cap \(cap) bytes"
        case .emptyPayload:
            return "sync snapshot payload is empty"
        }
    }
}

/// Per-book entry — whitelist fields only (see module header).
public struct SyncBook: Codable, Equatable {
    public var id: String
    public var fileName: String
    public var title: String?
    public var author: String?
    public var version: String?
    public var language: String?
    public var pageCount: Int
    /// "ok" | "error" (status word only; the error MESSAGE is never carried).
    public var status: String
    public var indexedAt: Double
    /// full | partial | needs-ocr | unknown (CoverageClassification raw value)
    public var coverage: String?

    /// Exact key set this type is allowed to serialize. Tests assert the
    /// encoded JSON never contains anything else.
    public static let whitelistedKeys: Set<String> = [
        "id", "fileName", "title", "author", "version", "language",
        "pageCount", "status", "indexedAt", "coverage",
    ]

    public init(id: String, fileName: String, title: String?, author: String?,
                version: String?, language: String?, pageCount: Int,
                status: String, indexedAt: Double, coverage: String?) {
        self.id = id
        self.fileName = fileName
        self.title = title
        self.author = author
        self.version = version
        self.language = language
        self.pageCount = pageCount
        self.status = status
        self.indexedAt = indexedAt
        self.coverage = coverage
    }

    /// Whitelist projection from a full index row: paths and fingerprints are
    /// dropped here, before any encoding can happen.
    public init(row: IndexStore.BookRow, coverage: String?) {
        self.init(id: row.id, fileName: row.fileName, title: row.title,
                  author: row.author, version: row.version, language: row.language,
                  pageCount: row.pageCount, status: row.status,
                  indexedAt: row.indexedAt, coverage: coverage)
    }
}

/// Aggregate coverage counters (numbers only; no root names — a root name is a
/// filesystem fact and this snapshot may cross devices where roots differ).
public struct SyncCoverage: Codable, Equatable {
    public var bookCount: Int
    public var pageCount: Int
    public var pagesWithoutText: Int?
    public var errorBooks: Int?
    public var lastIndexedAt: Double?

    public init(bookCount: Int, pageCount: Int, pagesWithoutText: Int?,
                errorBooks: Int?, lastIndexedAt: Double?) {
        self.bookCount = bookCount
        self.pageCount = pageCount
        self.pagesWithoutText = pagesWithoutText
        self.errorBooks = errorBooks
        self.lastIndexedAt = lastIndexedAt
    }

    public init(stats: IndexStore.CoverageStats, lastIndexedAt: Double?) {
        self.init(bookCount: stats.booksOK, pageCount: stats.pages,
                  pagesWithoutText: stats.pagesWithoutText,
                  errorBooks: stats.booksError, lastIndexedAt: lastIndexedAt)
    }
}

/// The versioned envelope.
public struct SyncSnapshot: Codable, Equatable {
    public var schemaVersion: Int
    public var createdAt: Date
    public var generator: String
    public var books: [SyncBook]
    public var history: [HistoryEntry]
    public var coverage: SyncCoverage?

    public init(schemaVersion: Int = SyncSchema.current, createdAt: Date,
                generator: String = "literaturesearch", books: [SyncBook],
                history: [HistoryEntry], coverage: SyncCoverage?) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.generator = generator
        self.books = books
        self.history = history
        self.coverage = coverage
    }

    /// Deduplicated copy: one book per id (newest indexedAt wins), one history
    /// entry per query (newest timestamp wins, order preserved).
    public func deduplicated() -> SyncSnapshot {
        var out = self
        var bestByID: [String: SyncBook] = [:]
        for book in books {
            if let existing = bestByID[book.id], existing.indexedAt > book.indexedAt {
                continue
            }
            bestByID[book.id] = book
        }
        out.books = bestByID.values.sorted { $0.id < $1.id }
        var bestByQuery: [String: HistoryEntry] = [:]
        var order: [String] = []
        for entry in history {
            if let existing = bestByQuery[entry.query] {
                if entry.at > existing.at { bestByQuery[entry.query] = entry }
            } else {
                bestByQuery[entry.query] = entry
                order.append(entry.query)
            }
        }
        out.history = order.compactMap { bestByQuery[$0] }
        return out
    }
}

extension SyncSnapshot {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, createdAt, generator, books, history, coverage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        generator = try c.decodeIfPresent(String.self, forKey: .generator) ?? "unknown"
        books = try c.decodeIfPresent([SyncBook].self, forKey: .books) ?? []
        history = try c.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
        coverage = try c.decodeIfPresent(SyncCoverage.self, forKey: .coverage)
    }
}

extension SyncBook {
    private enum CodingKeys: String, CodingKey {
        case id, fileName, title, author, version, language
        case pageCount, status, indexedAt, coverage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        indexedAt = try c.decodeIfPresent(Double.self, forKey: .indexedAt) ?? 0
        coverage = try c.decodeIfPresent(String.self, forKey: .coverage)
    }
}

public enum SyncSnapshotCodec {

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys] // deterministic bytes
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    public static func encode(_ snapshot: SyncSnapshot) throws -> Data {
        let data = try makeEncoder().encode(snapshot)
        guard data.count <= SyncSchema.maxEncodedBytes else {
            throw SyncError.payloadTooLarge(bytes: data.count, cap: SyncSchema.maxEncodedBytes)
        }
        return data
    }

    /// Fail-closed on unknown schema versions; tolerant of missing optional
    public static func decode(_ data: Data) throws -> SyncSnapshot {
        guard !data.isEmpty else { throw SyncError.emptyPayload }
        guard data.count <= SyncSchema.maxEncodedBytes else {
            throw SyncError.payloadTooLarge(bytes: data.count, cap: SyncSchema.maxEncodedBytes)
        }
        let snapshot = try makeDecoder().decode(SyncSnapshot.self, from: data)
        guard SyncSchema.decodable.contains(snapshot.schemaVersion) else {
            throw SyncError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        // Second line of defense: whatever a producer wrote, the decoded model
        // cannot hold paths/fingerprints/full text — they have no properties.
        return snapshot.deduplicated()
    }
}

// MARK: - Builder (index -> snapshot)

public enum SyncSnapshotBuilder {
    /// Builds a whitelist-only snapshot from an index store. Reads metadata
    /// and counters; page TEXT is never loaded (no page calls).
    public static func build(store: IndexStore,
                             history: [HistoryEntry],
                             now: Date = Date()) throws -> SyncSnapshot {
        let books = try store.allBooks()
        let statsByBook = Dictionary(try store.perBookPageStats().map { ($0.bookID, $0) },
                                     uniquingKeysWith: { a, _ in a })
        var syncBooks: [SyncBook] = []
        for row in books {
            let coverage = statsByBook[row.id]?.coverage.rawValue
            syncBooks.append(SyncBook(row: row, coverage: coverage))
        }
        let stats = try store.coverageStats()
        return SyncSnapshot(createdAt: now, books: syncBooks,
                            history: history,
                            coverage: SyncCoverage(stats: stats, lastIndexedAt: books.map(\.indexedAt).max()))
            .deduplicated()
    }
}

// MARK: - Cloud transport (protocol + replaceable adapters; NO real sync)
//
// development build: CloudKit is NOT wired up. This is a protocol seam so a
// real adapter can be dropped in later after entitlements/team exist. The
// in-memory adapter is what tests (and unsigned development) use. Nothing in
// this module claims the data reaches a cloud service.

public protocol SyncTransport {
    func upload(payload: Data, key: String) async throws
    func download(key: String) async throws -> Data?
}

/// Test/development adapter: payload stays in process memory.
public final class InMemorySyncTransport: SyncTransport {
    private var store: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func upload(payload: Data, key: String) async throws {
        storeSync(payload, key: key)
    }

    public func download(key: String) async throws -> Data? {
        loadSync(key: key)
    }

    // Locking lives in sync helpers (NSLock is unavailable from async contexts).
    private func storeSync(_ payload: Data, key: String) {
        lock.lock(); defer { lock.unlock() }
        store[key] = payload
    }

    private func loadSync(key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }
}

/// Placeholder for a future CloudKit adapter. Deliberately does nothing but
/// report that it is not configured — it must never pretend a record was
/// uploaded.
public struct UnconfiguredCloudTransport: SyncTransport, CustomStringConvertible {
    public struct NotConfigured: Error, CustomStringConvertible {
        public var description: String { "cloud sync is not configured (development build: no CloudKit container)" }
    }

    public init() {}
    public var description: String { "UnconfiguredCloudTransport (no real sync)" }

    public func upload(payload: Data, key: String) async throws { throw NotConfigured() }
    public func download(key: String) async throws -> Data? { throw NotConfigured() }
}
