import Foundation
@testable import LiteratureCore

// MARK: - Sync snapshot & watch summary suite (all synthetic)

enum SyncWatchSuite {
    static func makeStore() throws -> (IndexStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lit-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try IndexStore(path: dir.appendingPathComponent("index.db")), dir)
    }

    @discardableResult
    static func addBook(_ store: IndexStore, id: String, realPath: String, fileName: String,
                        pages: [String], status: String = "ok", title: String? = nil,
                        indexedAt: Double = 0) throws -> IndexStore.BookRow {
        let book = IndexStore.BookRow(
            id: id, realPath: realPath, rootPath: "/tmp/lit-synthetic-libs/secret-root",
            relPath: fileName, fileName: fileName,
            title: title, author: nil, version: nil, language: nil, metaSource: nil,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 1, mtime: 0,
            pageCount: max(pages.count, 1), status: status, indexedAt: indexedAt)
        try store.upsertBook(book)
        var rows: [IndexStore.PageRow] = []
        for (i, text) in pages.enumerated() {
            let n = normalizeForSearch(text)
            rows.append(IndexStore.PageRow(bookID: id, pageNumber: i + 1, textOriginal: text,
                                           textNorm: n.text, normStarts: n.starts, normEnds: n.ends))
        }
        try store.replacePages(bookID: id, rows)
        return book
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "SyncWatch", name: "snapshotExcludesPathsKeysAndFullText") {
                let (store, _) = try makeStore()
                let pageText = "FULLTEXT-MARKER-7f3 这是绝不能出设备的页面正文 synthetic"
                try addBook(store, id: "b1", realPath: "/tmp/lit-synthetic-libs/secret-root/secret-dir/a.pdf",
                            fileName: "a.pdf", pages: [pageText, "second page 第二页"], title: "书甲")
                try addBook(store, id: "b2", realPath: "/tmp/lit-synthetic-libs/secret-root/b.pdf",
                            fileName: "b.pdf", pages: ["plain 平凡"], status: "error")
                let syntheticAPIKey = "sk-synthetic-key-do-not-export-4242"
                let snapshot = try SyncSnapshotBuilder.build(
                    store: store,
                    history: [HistoryEntry(query: "检索词", at: Date(timeIntervalSince1970: 100), hitCount: 2)],
                    now: Date(timeIntervalSince1970: 200))
                let data = try SyncSnapshotCodec.encode(snapshot)
                let payload = String(decoding: data, as: UTF8.self)

                // Paths never appear (roots, dirs, absolute or relative).
                // (fileName alone IS whitelisted — a bare name is not a path.)
                try expectFalse(payload.contains("secret-root"), "path root leaked")
                try expectFalse(payload.contains("secret-dir"), "path dir leaked")
                try expectFalse(payload.contains("/tmp/lit"), "absolute path leaked")
                try expectFalse(payload.contains("realPath"), "realPath key leaked")
                try expectFalse(payload.contains("rootPath"), "rootPath key leaked")
                try expectFalse(payload.contains("relPath"), "relPath key leaked")
                try expectFalse(payload.contains("fingerprint"), "fingerprint leaked")
                // Full text never appears.
                try expectFalse(payload.contains("FULLTEXT-MARKER"), "page full text leaked")
                try expectFalse(payload.contains("绝不能出设备"), "page full text (CJK) leaked")
                try expectFalse(payload.contains("second page"), "page text leaked")
                // Keys/secrets never appear (even a synthetic one).
                try expectFalse(payload.contains(syntheticAPIKey), "API key leaked")

                // Structural whitelist: every serialized book object uses ONLY
                // whitelisted keys.
                let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let rawBooks = try expectNotNil(raw?["books"] as? [[String: Any]], "books array missing")
                try expectEqual(rawBooks.count, 2)
                for book in rawBooks {
                    let keys = Set(book.keys)
                    try expectTrue(keys.isSubset(of: SyncBook.whitelistedKeys),
                                   "non-whitelisted book keys: \(keys.subtracting(SyncBook.whitelistedKeys))")
                }
                // Decoded model has no path-typed property to hold a path.
                try expectEqual(snapshot.books.first?.fileName, "a.pdf")
                try expectEqual(snapshot.books.count, 2)
            },

            TestDesc(suite: "SyncWatch", name: "snapshotVersioningUnknownFailsClosedLegacyTolerated") {
                // Unknown future version must fail closed.
                var future = SyncSnapshot(createdAt: Date(timeIntervalSince1970: 1), books: [],
                                          history: [], coverage: nil)
                future.schemaVersion = 99
                let futureData = try SyncSnapshotCodec.makeTestEncoder().encode(future)
                try expectThrows(try SyncSnapshotCodec.decode(futureData), "v99 must be rejected")

                let legacy: [String: Any] = [
                    "schemaVersion": 1,
                    "createdAt": 1234.0,
                    "books": [["id": "b1", "fileName": "a.pdf", "pageCount": 3, "status": "ok"]],
                    "history": [["query": "旧查询", "at": 100.0, "hitCount": 1]],
                ]
                let legacyData = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
                let decoded = try SyncSnapshotCodec.decode(legacyData)
                try expectEqual(decoded.books.count, 1)
                try expectNil(decoded.books.first?.title)
                try expectNil(decoded.books.first?.coverage)
                try expectNil(decoded.coverage)
                try expectEqual(decoded.history.first?.query, "旧查询")
            },

            TestDesc(suite: "SyncWatch", name: "snapshotDeduplicatesBooksAndHistory") {
                let snapshot = SyncSnapshot(
                    createdAt: Date(timeIntervalSince1970: 10),
                    books: [
                        SyncBook(id: "b1", fileName: "old.pdf", title: nil, author: nil, version: nil,
                                 language: nil, pageCount: 1, status: "ok", indexedAt: 1, coverage: "unknown"),
                        SyncBook(id: "b1", fileName: "new.pdf", title: nil, author: nil, version: nil,
                                 language: nil, pageCount: 5, status: "ok", indexedAt: 9, coverage: "full"),
                        SyncBook(id: "b2", fileName: "b.pdf", title: nil, author: nil, version: nil,
                                 language: nil, pageCount: 2, status: "ok", indexedAt: 2, coverage: "partial"),
                    ],
                    history: [
                        HistoryEntry(query: "同一词", at: Date(timeIntervalSince1970: 1), hitCount: 1),
                        HistoryEntry(query: "另一词", at: Date(timeIntervalSince1970: 2), hitCount: 2),
                        HistoryEntry(query: "同一词", at: Date(timeIntervalSince1970: 3), hitCount: 9),
                    ],
                    coverage: nil)
                let dedup = snapshot.deduplicated()
                try expectEqual(dedup.books.count, 2)
                try expectEqual(dedup.books.first?.id, "b1")
                try expectEqual(dedup.books.first?.fileName, "new.pdf", "newest indexedAt must win")
                try expectEqual(dedup.history.count, 2)
                try expectEqual(dedup.history.first?.query, "同一词")
                try expectEqual(dedup.history.first?.hitCount, 9, "newest entry must win")
                // decode also dedups (defense in depth).
                let data = try SyncSnapshotCodec.makeTestEncoder().encode(snapshot)
                let viaDecode = try SyncSnapshotCodec.decode(data)
                try expectEqual(viaDecode.books.count, 2)
                try expectEqual(viaDecode.history.count, 2)
            },

            TestDesc(suite: "SyncWatch", name: "snapshotAndWatchPayloadSizeCapsEnforced") {
                // Over-cap payload fails closed before any parsing.
                let oversized = Data(repeating: UInt8(ascii: "{"), count: SyncSchema.maxEncodedBytes + 1)
                try expectThrows(try SyncSnapshotCodec.decode(oversized), "oversized snapshot must be rejected")
                let oversizedWatch = Data(repeating: UInt8(ascii: "{"),
                                          count: WatchSummaryLimits.maxEncodedBytes + 1)
                try expectThrows(try WatchSummaryCodec.decode(oversizedWatch), "oversized watch payload must be rejected")
                // Empty payloads fail closed too.
                try expectThrows(try SyncSnapshotCodec.decode(Data()))
                try expectThrows(try WatchSummaryCodec.decode(Data()))
                // Round trip inside the cap succeeds.
                let small = SyncSnapshot(createdAt: Date(timeIntervalSince1970: 5), books: [],
                                         history: [], coverage: nil)
                let back = try SyncSnapshotCodec.decode(try SyncSnapshotCodec.encode(small))
                try expectEqual(back, small)
            },

            TestDesc(suite: "SyncWatch", name: "builderProjectsCoverageCategoryWithoutContent") {
                let (store, _) = try makeStore()
                try addBook(store, id: "full1", realPath: "/x/full1.pdf", fileName: "full1.pdf",
                            pages: ["alpha", "beta"])
                try addBook(store, id: "scan1", realPath: "/x/scan1.pdf", fileName: "scan1.pdf",
                            pages: ["", ""])
                let snapshot = try SyncSnapshotBuilder.build(store: store, history: [],
                                                             now: Date(timeIntervalSince1970: 7))
                try expectEqual(snapshot.books.count, 2)
                let byID = Dictionary(snapshot.books.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                try expectEqual(byID["full1"]?.coverage, "full")
                try expectEqual(byID["scan1"]?.coverage, "needs-ocr")
                try expectEqual(snapshot.coverage?.bookCount, 2)
                try expectEqual(snapshot.coverage?.pageCount, 4)
                try expectEqual(snapshot.coverage?.pagesWithoutText, 2)
                // Builder never carried text out of the store.
                let payload = String(decoding: try SyncSnapshotCodec.encode(snapshot), as: UTF8.self)
                try expectFalse(payload.contains("alpha"), "page text leaked via builder")
            },

            TestDesc(suite: "SyncWatch", name: "watchSummaryTruncatesAndRoundTrips") {
                var longQuery = ""
                for _ in 0..<30 { longQuery += "很长的检索词" }
                var history: [HistoryEntry] = []
                for i in 0..<12 {
                    history.append(HistoryEntry(query: i == 0 ? longQuery : "词\(i)",
                                                at: Date(timeIntervalSince1970: Double(i)), hitCount: i))
                }
                let coverage = CoverageSnapshot(bookCount: 3, pageCount: 40, lastIndexedAt: nil,
                                                rootName: "/tmp/private-root", rootCount: 1,
                                                pagesWithoutText: 4, errorBooks: 1,
                                                lastRunExcluded: nil, lastRunUnsupported: nil, lastRunFailed: nil)
                let summary = WatchSummaryBuilder.build(coverage: coverage, history: history,
                                                        now: Date(timeIntervalSince1970: 1000))
                try expectTrue(summary.truncated, "12>3 queries must mark truncated")
                try expectEqual(summary.queries.count, WatchSummaryLimits.maxQueries)
                for q in summary.queries {
                    try expectTrue(q.count <= WatchSummaryLimits.maxQueryLength, "query over length cap")
                }
                try expectEqual(summary.queries.first?.count, WatchSummaryLimits.maxQueryLength,
                                "long query must be shortened, not dropped")
                try expectEqual(summary.historyCount, 12)
                // Root name (a filesystem fact) must not cross to the watch stamp/payload.
                let data = try WatchSummaryCodec.encode(summary)
                try expectTrue(data.count <= WatchSummaryLimits.maxEncodedBytes)
                let payload = String(decoding: data, as: UTF8.self)
                try expectFalse(payload.contains("private-root"), "root name leaked to watch")
                try expectFalse(payload.contains(".pdf"), "file name leaked to watch")
                let back = try WatchSummaryCodec.decode(data)
                try expectEqual(back, summary)
                try expectFalse(back.isExpired(now: Date(timeIntervalSince1970: 1000 + 60)))
                try expectTrue(back.isExpired(now: Date(timeIntervalSince1970: 1000 + 7 * 3600)))
            },

            TestDesc(suite: "SyncWatch", name: "expiredFingerprintMarksSummaryStale") {
                let history = [HistoryEntry(query: "q", at: Date(timeIntervalSince1970: 1), hitCount: 0)]
                let coverage = CoverageSnapshot(bookCount: 1, pageCount: 2, lastIndexedAt: nil,
                                                rootName: nil, rootCount: nil)
                let summary = WatchSummaryBuilder.build(coverage: coverage, history: history,
                                                        now: Date(timeIntervalSince1970: 50))
                // Same state derives the same stamp on any device.
                try expectTrue(summary.stampMatches(
                    currentStamp: WatchSummaryBuilder.indexStamp(coverage: coverage, history: history)))
                // State moved -> stamp mismatch -> stale by fingerprint.
                let moved = CoverageSnapshot(bookCount: 2, pageCount: 2, lastIndexedAt: nil,
                                             rootName: nil, rootCount: nil)
                try expectFalse(summary.stampMatches(
                    currentStamp: WatchSummaryBuilder.indexStamp(coverage: moved, history: history)))
                try expectFalse(summary.stampMatches(currentStamp: "ws1-deadbeef"))
                // Different now does not change the stamp (content-derived only).
                let later = WatchSummaryBuilder.build(coverage: coverage, history: history,
                                                      now: Date(timeIntervalSince1970: 9000))
                try expectTrue(later.stampMatches(currentStamp: summary.indexStamp))
                // Default TTL expiry by age.
                try expectTrue(summary.isExpired(now: Date(timeIntervalSince1970: 50 + 6 * 3600 + 1)))
                try expectFalse(summary.isExpired(now: Date(timeIntervalSince1970: 50)))
            },

            TestDesc(suite: "SyncWatch", name: "deepLinkRoundTripForPhoneAndWatch") {
                // Phone widget + watch complication share the same contract.
                let link = try expectNotNil(DeepLink.search(query: "计算理论 deep").build(), "link builds")
                try expectEqual(link.absoluteString, "literaturesearch://search?q=%E8%AE%A1%E7%AE%97%E7%90%86%E8%AE%BA%20deep")
                let parsed = try expectNotNil(DeepLink.parse(link), "link parses")
                try expectEqual(parsed, .search(query: "计算理论 deep"))
                // Empty queries never produce a link on either target.
                try expectNil(DeepLink.search(query: "   ").build())
                try expectNil(DeepLink.parse(URL(string: "literaturesearch://other?q=x") ?? URL(fileURLWithPath: "/")))
                try expectNil(DeepLink.parse(URL(string: "https://example.com/search?q=x") ?? URL(fileURLWithPath: "/")))
                // Watch summary queries are trim-safe deep-link inputs.
                let (queries, _) = WatchSummaryBuilder.truncate(queries: ["  可深链  ", "", "   "], historyCount: 1)
                try expectEqual(queries, ["可深链"])
                for q in queries {
                    try expectNotNil(DeepLink.search(query: q).build(), "truncated query must stay linkable")
                }
            },

            TestDesc(suite: "SyncWatch", name: "transportInMemoryWorksCloudHonestlyRefuses") {
                let memory = InMemorySyncTransport()
                let payload = try SyncSnapshotCodec.encode(
                    SyncSnapshot(createdAt: Date(), books: [], history: [], coverage: nil))
                try await memory.upload(payload: payload, key: "snapshot")
                let back = try expectNotNil(try await memory.download(key: "snapshot"), "download must return payload")
                try expectEqual(back, payload)

                let cloud = UnconfiguredCloudTransport()
                try await expectThrowsAsync({ try await cloud.upload(payload: payload, key: "s") },
                                            "unconfigured cloud must refuse, never pretend success")
                try await expectThrowsAsync({ try await cloud.download(key: "s") },
                                            "unconfigured cloud must refuse, never fake data")
            },
        ]
    }
}

// MARK: - Test seam: encoder with fixed settings (kept out of the prod API)

extension SyncSnapshotCodec {
    static func makeTestEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}
