import Foundation

/// Gate for publishing coverage statistics into the App Group shared snapshot.
///
/// The shared snapshot is the only surface the WidgetKit extension reads, so it
/// must always describe the canonical per-user app database. Indexing a
/// scratch, synthetic, or copy-on-write database (tests, E2E, perf probes) must
/// never overwrite it: a fixture run would otherwise replace the real library's
/// coverage with its own counters. Publication therefore happens only when the
/// store's database IS the canonical one, or when the operator asks explicitly.
public enum CoveragePublication {
    /// The database the macOS app opens (AppState opens the same path).
    public static var canonicalAppDatabaseURL: URL {
        resolveCanonicalAppDatabaseURL(
            from: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)).url
    }

    /// 参数化纯函数：urls 注入可测；返回 (落点, 警告)。警告
    /// （降级家目录）由调用方如实展示，与前者同款语义。
    public static func resolveCanonicalAppDatabaseURL(
        from urls: [URL]) -> (url: URL, warning: String?) {
        let base = AppSupportPaths.resolveBase(from: urls)
        let support = base.url.appendingPathComponent("LiteratureSearch", isDirectory: true)
        return (support.appendingPathComponent("index.db"), base.warning)
    }

    /// Fail closed: publish only for the canonical database unless the
    /// operator passes the explicit publish flag.
    public static func shouldPublish(dbURL: URL, explicit: Bool) -> Bool {
        if explicit { return true }
        return dbURL.standardizedFileURL.path == canonicalAppDatabaseURL.standardizedFileURL.path
    }
}
