import Foundation
@testable import LiteratureCore

enum IndexSearchSuite {
    static func buildLibrary(_ dir: URL) {
        Fixtures.makePDF(pages: [
            .init(lines: ["第一章 导论", "这是中文测试页面。", "The theory of computation begins here."]),
            .init(lines: ["第二章 方法", "Chapter two mentions 计算理论 clearly. Graph theory rocks."]),
        ], in: dir, named: "bookA.pdf")
        Fixtures.makePDF(pages: [
            .init(lines: ["Catalogue of Sample Works", "English only volume."]),
        ], in: dir, named: "bookB.pdf")
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "Performance", name: "openIndexAndRepeatBookLevelHotSearch") {
                guard let raw = ProcessInfo.processInfo.environment["LITERATURESEARCH_PERF_DB"] else { return }
                let term = ProcessInfo.processInfo.environment["LITERATURESEARCH_PERF_TERM"] ?? "norm"
                let startOpen = Date()
                let store = try IndexStore(path: URL(fileURLWithPath: raw))
                let opened = Date()
                let service = SearchService(store: store)
                let startFirst = Date()
                let first = try service.matchingBooks(term)
                let firstDone = Date()
                let second = try service.matchingBooks(term)
                let secondDone = Date()
                let metrics: [String: Any] = [
                    "term": term,
                    "store_open_seconds": opened.timeIntervalSince(startOpen),
                    "first_hot_query_seconds": firstDone.timeIntervalSince(startFirst),
                    "repeat_hot_query_seconds": secondDone.timeIntervalSince(firstDone),
                    "matching_books": first.count,
                    "repeat_count_matches": first.count == second.count
                ]
                let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
                print("PERFORMANCE " + String(decoding: data, as: UTF8.self))
                // Phase trace (env-gated): where does a cold book-level query spend time?
                if ProcessInfo.processInfo.environment["LITERATURESEARCH_PERF_TRACE"] == "1" {
                    let terms = ["制度", "规范"]
                    for t in terms {
                        let a = Date()
                        let ids = try store.candidatePageIDs(term: t)
                        let b = Date()
                        let counts = try store.matchingPageCounts(rowIDs: Array(Set(ids)))
                        let c = Date()
                        let nat = try store.nativeTextPageCountsByBook()
                        let d = Date()
                        let trace: [String: Any] = [
                            "term": t,
                            "candidates": ids.count,
                            "candidate_seconds": b.timeIntervalSince(a),
                            "counts_seconds": c.timeIntervalSince(b),
                            "native_seconds": d.timeIntervalSince(c),
                            "books_with_counts": counts.count,
                            "books_total": nat.count
                        ]
                        print("PHASETRACE " + String(decoding: try JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys]), as: UTF8.self))
                    }
                }
                try expectTrue(first.count > 0, "private fixture index must contain matches")
                try expectEqual(first.count, second.count, "repeat queries return the same aggregate")
                let target = perfLimit(2.0, relaxed: 10.0, "repeat book-level query")
                try expectTrue((metrics["repeat_hot_query_seconds"] as! Double) < target,
                               "repeat book-level query must stay below the \(target)s target")
            },
            TestDesc(suite: "IndexSearch", name: "physicalPagesAreOneBasedAndCorrect") {
                let dir = Fixtures.makeTempDir("idx-search")
                defer { Fixtures.cleanup(dir) }
                buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                let summary = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                try expectEqual(summary.indexedNew, 2)
                let books = try store.allBooks().sorted { $0.fileName < $1.fileName }
                try expectEqual(books.count, 2)
                let bookA = try expectNotNil(books.first { $0.fileName == "bookA.pdf" })
                try expectEqual(bookA.pageCount, 2)
                let p1 = try store.page(bookID: bookA.id, pageNumber: 1)
                let p2 = try store.page(bookID: bookA.id, pageNumber: 2)
                try expectEqual(p1?.pageNumber, 1)
                try expectEqual(p2?.pageNumber, 2)
                try expectTrue(p1?.textOriginal.contains("导论") ?? false)
                try expectTrue(p2?.textOriginal.contains("计算理论") ?? false)
                try expectNil(p1?.label)
                try expectNil(p1?.printedPage, "printed folio must be unknown, not guessed")
            },
            TestDesc(suite: "IndexSearch", name: "chineseSubstringSearchLandsOnRightPage") {
                let dir = Fixtures.makeTempDir("idx-cjk")
                defer { Fixtures.cleanup(dir) }
                buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let hits = try SearchService(store: store).search("计算理论")
                try expectEqual(hits.count, 1)
                try expectEqual(hits[0].physicalPage, 2)
                try expectTrue(hits[0].matches[0].displayTerm.contains("计算理论"))
                try expectTrue(hits[0].snippet.contains("计算理论"))
                try expectEqual(hits[0].fileName, "bookA.pdf")
            },
            TestDesc(suite: "IndexSearch", name: "twoCharacterChineseQuery") {
                let dir = Fixtures.makeTempDir("idx-cjk2")
                defer { Fixtures.cleanup(dir) }
                buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let hits = try SearchService(store: store).search("方法")
                try expectEqual(hits.count, 1)
                try expectEqual(hits[0].physicalPage, 2)
            },
            TestDesc(suite: "IndexSearch", name: "englishCaseInsensitive") {
                let dir = Fixtures.makeTempDir("idx-en")
                defer { Fixtures.cleanup(dir) }
                buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let hits = try SearchService(store: store).search("GRAPH THEORY")
                try expectFalse(hits.isEmpty)
                try expectTrue(hits.allSatisfy { $0.matches.count == 2 }, "both terms matched")
            },
            TestDesc(suite: "IndexSearch", name: "multiTermANDSemantics") {
                let dir = Fixtures.makeTempDir("idx-and")
                defer { Fixtures.cleanup(dir) }
                buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let hits = try SearchService(store: store).search("graph 计算理论")
                try expectEqual(hits.count, 1)
                try expectEqual(hits[0].physicalPage, 2)
            },
            TestDesc(suite: "IndexSearch", name: "specialCharactersMatchLiterally") {
                let dir = Fixtures.makeTempDir("idx-special")
                defer { Fixtures.cleanup(dir) }
                buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let service = SearchService(store: store)
                let noHits = try service.search("100%_")
                try expectTrue(noHits.isEmpty, "LIKE/FTS metacharacters are literal; not in corpus -> no hits")
                let punct = try service.search("rocks.")
                try expectEqual(punct.count, 1)
                try expectEqual(punct[0].physicalPage, 2)
            },
            TestDesc(suite: "IndexSearch", name: "unknownMetadataIsExplicitlyNil") {
                let dir = Fixtures.makeTempDir("idx-meta")
                defer { Fixtures.cleanup(dir) }
                buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let hits = try SearchService(store: store).search("graph")
                let hit = try expectNotNil(hits.first, "no hits")
                try expectNil(hit.title, "title unknown -> nil, never guessed from the file name")
                try expectNil(hit.author)
                try expectNil(hit.version)
                try expectNil(hit.pageLabel)
                try expectNil(hit.printedPage)
            },
            TestDesc(suite: "IndexSearch", name: "programmaticBoundsOnOriginalPage") {
                let dir = Fixtures.makeTempDir("idx-bounds")
                defer { Fixtures.cleanup(dir) }
                buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let hits = try SearchService(store: store).search("计算理论")
                let hit = try expectNotNil(hits.first)
                let range = try expectNotNil(hit.matches.first?.originalUTF16Range, "no match range")
                let bounds = PDFTextExtractor.selectionBounds(
                    fileURL: URL(fileURLWithPath: hit.filePath),
                    physicalPage: hit.physicalPage,
                    originalUTF16Range: range
                )
                let rect = try expectNotNil(bounds, "match must be programmatically locatable on the physical page")
                try expectTrue(rect.width > 0)
                try expectTrue(rect.height > 0)
            },
            TestDesc(suite: "IndexSearch", name: "emptyQueryThrows") {
                let dir = Fixtures.makeTempDir("idx-empty")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                try expectThrows(try SearchService(store: store).search("   "))
            },
            TestDesc(suite: "IndexSearch", name: "likeFallbackModeWorks") {
                let dir = Fixtures.makeTempDir("idx-fallback")
                defer { Fixtures.cleanup(dir) }
                buildLibrary(dir)
                let store = try IndexStore(path: dir.appendingPathComponent("fallback.db"),
                                           options: IndexStore.Options(forceFallbackSearch: true))
                try expectEqual(store.searchMode, IndexStore.SearchMode.likeFallback)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let hits = try SearchService(store: store).search("计算理论")
                try expectEqual(hits.count, 1)
                try expectEqual(hits[0].physicalPage, 2)
            },
            TestDesc(suite: "IndexSearch", name: "bookIDIsDerivedFromContentNotFilename") {
                let dir = Fixtures.makeTempDir("idx-bookid")
                defer { Fixtures.cleanup(dir) }
                buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                for book in try store.allBooks() {
                    try expectTrue(book.id.hasPrefix("b"))
                    try expectEqual(book.id.count, 21, "\"b\" + 20 hex chars of the initial fingerprint")
                    try expectTrue(book.fingerprint.hasPrefix(String(book.id.dropFirst())))
                }
            },
            TestDesc(suite: "BigramInvertedIndex", name: "rebuildEnablesInvertedPathAndResultsMatch") {
                let dir = Fixtures.makeTempDir("idx-bidx-1")
                defer { Fixtures.cleanup(dir) }
                buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                guard store.searchMode == .fts5Trigram else { return }
                // Before the explicit rebuild the index is empty: candidates
                // must come from the FTS fallback, i.e. nil from the inverted path.
                try expectNil(try store.candidatePageIDsViaInvertedIndex(bigrams: ["计算"]))
                let built = try store.ensureBigramIndexFresh()
                try expectTrue(built, "first ensure after indexing must rebuild")
                try expectFalse(try store.ensureBigramIndexFresh(), "second ensure is a no-op (not dirty)")
                let via = try store.candidatePageIDsViaInvertedIndex(bigrams: ["计算"])
                try expectNotNil(via, "index built → bigram lookup must answer")
                let direct = try store.candidatePageIDs(term: "计算")
                try expectEqual(via!.count, direct.count, "inverted path agrees with the reference search")
                let hits = try SearchService(store: store).search("方法")
                try expectEqual(hits.count, 1)
                try expectEqual(hits[0].physicalPage, 2)
            },
            TestDesc(suite: "BigramInvertedIndex", name: "pageWriteMarksDirtyAndRebuildSeesNewContent") {
                let dir = Fixtures.makeTempDir("idx-bidx-2")
                defer { Fixtures.cleanup(dir) }
                buildLibrary(dir)
                let store = try Fixtures.openStore(in: dir)
                let _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                guard store.searchMode == .fts5Trigram else { return }
                try expectTrue(try store.ensureBigramIndexFresh())
                let bookA = try expectNotNil(try store.allBooks().first { $0.fileName == "bookA.pdf" })
                // New page content the built index has never seen. Offsets are
                // the identity map (textNorm == textOriginal), like the engine
                // computes for unmodified CJK text.
                let orig = "第三章 独特词汇出现。"
                var starts: [Int32] = [], ends: [Int32] = []
                var acc = 0
                for ch in orig {
                    starts.append(Int32(acc))
                    acc += ch.utf16.count
                    ends.append(Int32(acc))
                }
                let page = IndexStore.PageRow(bookID: bookA.id, pageNumber: 3, label: nil, printedPage: nil,
                                              textOriginal: orig, textNorm: orig,
                                              normStarts: starts, normEnds: ends)
                try store.replacePages(bookID: bookA.id, [page])
                // Write marked the index dirty: inverted path must refuse (nil →
                // fallback keeps results correct), not serve stale answers.
                try expectNil(try store.candidatePageIDsViaInvertedIndex(bigrams: ["独特"]))
                let hitsBefore = try SearchService(store: store).search("独特词汇")
                try expectEqual(hitsBefore.count, 1, "stale index falls back and still finds the new page")
                try expectTrue(try store.ensureBigramIndexFresh(), "dirty flag forces one rebuild")
                let via = try store.candidatePageIDsViaInvertedIndex(bigrams: ["独特"])
                try expectNotNil(via)
                try expectFalse(via!.isEmpty, "rebuilt index contains the new page")
                let hitsAfter = try SearchService(store: store).search("独特词汇")
                try expectEqual(hitsAfter.count, 1)
                try expectEqual(hitsAfter[0].physicalPage, 3)
            },
        ]
    }
}
