import Foundation

// MARK: - Shared daily-quote snapshot (AppGroup surface)
//
// The app picks one quote per day (QuoteExtractor) and writes it here so the
// widget can display it. The widget sandbox cannot read index.db; this file
// is the ONLY quote surface crossing into the widget, and it deliberately
// carries just one excerpt plus its citation coordinates — no pool, no paths,
// no fingerprints, no AI state.

public struct SharedQuoteState: Codable, Equatable {
    public var sentence: String
    public var bookFileName: String
    /// 1-based physical page of the original book.
    public var physicalPage: Int
    /// yyyy-MM-dd in the local calendar — the day this quote was picked for.
    public var date: String

    public init(sentence: String, bookFileName: String, physicalPage: Int, date: String) {
        self.sentence = sentence
        self.bookFileName = bookFileName
        self.physicalPage = physicalPage
        self.date = date
    }
}

/// File-backed quote store. The app writes it; the widget reads it.
/// The location follows SharedHistoryStore's resolution strategy: AppGroup
/// container when the group is available (signed app + widget), otherwise
/// Application Support (documented degradation for unsigned dev builds).
public final class SharedQuoteStore {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Resolves the quote file URL for the given app group, falling back to
    /// Application Support when the group container is unavailable.
    public static func quoteFileURL(appGroupID: String = SharedHistoryStore.defaultAppGroupID,
                                    fallbackDirectory: URL? = nil) -> URL {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent("quote-state.json")
        }
        let base = fallbackDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("LiteratureSearch", isDirectory: true)
            .appendingPathComponent("quote-state.json")
    }

    public func load() -> SharedQuoteState? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(SharedQuoteState.self, from: data) else {
            return nil
        }
        return state
    }

    public func save(_ state: SharedQuoteState) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
