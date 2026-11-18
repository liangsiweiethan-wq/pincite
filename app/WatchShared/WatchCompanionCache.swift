import Foundation

// Shared file surface between the watch APP and the watch WIDGET .
// The app receives the companion payload (daily quote + reading progress)
// over WatchConnectivity and caches the raw bytes here; the widget timeline
// reads the same bytes. The payload itself is produced by the core
// (WatchCompanionCodec) — sentence/title/page/date only, no paths, no text,
// no credentials. Shape mirrors WatchSummaryCache exactly.

struct WatchCompanionCache {
    static let appGroupID = "group.com.example.literaturesearch.shared"
    static let fileName = "watch-companion.json"

    static func fileURL() -> URL {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return container.appendingPathComponent(fileName)
        }
        // Documented degradation: unsigned development builds have no AppGroup.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("LiteratureSearch", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func save(_ data: Data) {
        let url = fileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> Data? {
        try? Data(contentsOf: fileURL())
    }
}
