import Foundation

// MARK: - Shared history & coverage snapshot (AppGroup surface)
//
// This is the ONLY data shape shared with the widget. It intentionally contains
// no original text and no snippets — history entries carry the query string and
// hit counts; coverage carries counters and timestamps. Types make it impossible
// to smuggle page content into the widget surface.

public struct HistoryEntry: Codable, Equatable {
    public var query: String
    public var at: Date
    public var hitCount: Int

    public init(query: String, at: Date, hitCount: Int) {
        self.query = query
        self.at = at
        self.hitCount = hitCount
    }
}

public struct CoverageSnapshot: Codable, Equatable {
    public var bookCount: Int
    public var pageCount: Int
    public var lastIndexedAt: Date?
    /// Set only when the index covers exactly one root; nil for multiple roots
    /// (an aggregate must not be labelled with a single root's name).
    public var rootName: String?
    public var rootCount: Int?
    /// Indexed pages whose text is empty — OCR is NOT performed, so they stay
    /// without text until a future version adds it explicitly.
    public var pagesWithoutText: Int?
    public var errorBooks: Int?
    /// Last-run counters (explicit user action): excluded / unsupported / failed.
    public var lastRunExcluded: Int?
    public var lastRunUnsupported: Int?
    public var lastRunFailed: Int?

    public init(bookCount: Int, pageCount: Int, lastIndexedAt: Date?, rootName: String?,
                rootCount: Int? = nil, pagesWithoutText: Int? = nil, errorBooks: Int? = nil,
                lastRunExcluded: Int? = nil, lastRunUnsupported: Int? = nil, lastRunFailed: Int? = nil) {
        self.bookCount = bookCount
        self.pageCount = pageCount
        self.lastIndexedAt = lastIndexedAt
        self.rootName = rootName
        self.rootCount = rootCount
        self.pagesWithoutText = pagesWithoutText
        self.errorBooks = errorBooks
        self.lastRunExcluded = lastRunExcluded
        self.lastRunUnsupported = lastRunUnsupported
        self.lastRunFailed = lastRunFailed
    }
}

struct SharedState: Codable {
    var history: [HistoryEntry] = []
    var coverage: CoverageSnapshot?
}

/// File-backed shared store. The app writes it; the widget reads it.
/// The file location comes from the AppGroup container when the group is
/// available (signed app + widget), otherwise from Application Support
/// (documented degradation; unsigned development builds have no AppGroup).
public final class SharedHistoryStore {
    public static let defaultAppGroupID = "group.com.example.literaturesearch.shared"
    public static let maxHistoryEntries = 20

    public let fileURL: URL
    private let lock = NSLock()

    /// Resolves the shared file URL for the given app group, falling back to
    /// Application Support when the group container is unavailable.
    public static func sharedFileURL(appGroupID: String = SharedHistoryStore.defaultAppGroupID,
                                     fallbackDirectory: URL? = nil) -> URL {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("shared-state.json")
        }
        let base = fallbackDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("LiteratureSearch", isDirectory: true)
            .appendingPathComponent("shared-state.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func record(query: String, hitCount: Int, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var state = loadLocked()
        state.history.removeAll { $0.query == query }
        state.history.insert(HistoryEntry(query: query, at: now, hitCount: hitCount), at: 0)
        if state.history.count > Self.maxHistoryEntries {
            state.history = Array(state.history.prefix(Self.maxHistoryEntries))
        }
        saveLocked(state)
    }

    public func history(limit: Int = SharedHistoryStore.maxHistoryEntries) -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(loadLocked().history.prefix(limit))
    }

    public func coverage() -> CoverageSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().coverage
    }

    public func update(coverage: CoverageSnapshot) {
        lock.lock(); defer { lock.unlock() }
        var state = loadLocked()
        state.coverage = coverage
        saveLocked(state)
    }

    // MARK: Internals

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970 // lossless, avoids truncation
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    private func loadLocked() -> SharedState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? Self.decoder.decode(SharedState.self, from: data) else {
            return SharedState()
        }
        return state
    }

    private func saveLocked(_ state: SharedState) {
        if let data = try? Self.encoder.encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
