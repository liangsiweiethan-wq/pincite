import Foundation
@testable import LiteratureCore

// MARK: - verify 相页文本源测试

enum PageTextSourceSuite {
    static func buildLibrary(_ dir: URL) {
        Fixtures.makePDF(pages: [
            .init(lines: ["第一章 导论", "这是中文测试页面。", "The theory of computation begins here."]),
            .init(lines: ["第二章 方法", "Chapter two mentions 计算理论 clearly. Graph theory rocks."]),
        ], in: dir, named: "bookA.pdf")
    }

    /// 索引一册并取其全部页 rowID（输入序即 store 契约序的原料）。
    static func indexedStoreAndRowIDs(_ dir: URL) async throws -> (IndexStore, IndexStore.BookRow, [String]) {
        buildLibrary(dir)
        let store = try Fixtures.openStore(in: dir)
        _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
        let book = try expectNotNil(try store.allBooks().first { $0.fileName == "bookA.pdf" })
        let rowIDs = Array(try store.candidateRowIDs(bookID: book.id))
        try expectTrue(!rowIDs.isEmpty, "fixture book must have page rows")
        return (store, book, rowIDs)
    }

    /// PageRow 公开字段逐一比对（文本域＝下游语义的消费面）。
    static func assertRowsEqual(_ a: [IndexStore.PageRow], _ b: [IndexStore.PageRow], _ label: String) throws {
        try expectEqual(a.count, b.count, "\(label): row count must match")
        for (i, (x, y)) in zip(a, b).enumerated() {
            try expectEqual(x.bookID, y.bookID, "\(label)[\(i)] bookID")
            try expectEqual(x.pageNumber, y.pageNumber, "\(label)[\(i)] pageNumber")
            try expectEqual(x.label, y.label, "\(label)[\(i)] label")
            try expectEqual(x.printedPage, y.printedPage, "\(label)[\(i)] printedPage")
            try expectEqual(x.textOriginal, y.textOriginal, "\(label)[\(i)] textOriginal")
            try expectEqual(x.textNorm, y.textNorm, "\(label)[\(i)] textNorm")
            try expectEqual(x.normStarts, y.normStarts, "\(label)[\(i)] normStarts")
            try expectEqual(x.normEnds, y.normEnds, "\(label)[\(i)] normEnds")
        }
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "PageTextSource", name: "sqlitePassthroughEqualsStorePages") {
                let dir = Fixtures.makeTempDir("pts-passthrough")
                defer { Fixtures.cleanup(dir) }
                let (store, _, rowIDs) = try await indexedStoreAndRowIDs(dir)
                let viaSource = try SQLitePageTextSource(store: store).pages(rowIDs: rowIDs)
                let direct = try store.pages(rowIDs: rowIDs)
                try assertRowsEqual(viaSource, direct, "passthrough")
            },

            TestDesc(suite: "PageTextSource", name: "sidecarFourStateFallbackMatrixMatchesStore") {
                let dir = Fixtures.makeTempDir("pts-sidecar")
                defer { Fixtures.cleanup(dir) }
                let (store, book, rowIDs) = try await indexedStoreAndRowIDs(dir)
                let direct = try store.pages(rowIDs: rowIDs)

                // 态1 命中：按书指纹写入真实抽取条目（同 sha＋同归一化版本）。
                let cacheDir = dir.appendingPathComponent("text-cache-hit")
                let cache = ExtractionTextCache(directory: cacheDir)
                let pdf = dir.appendingPathComponent("bookA.pdf")
                let extraction = try PDFTextExtractor.extract(url: pdf)
                try cache.store(fileSHA256: book.fingerprint, extraction)
                let hitSource = SidecarPageTextSource(store: store, cache: cache)
                try assertRowsEqual(try hitSource.pages(rowIDs: rowIDs), direct, "state-hit")

                // 态2 未命中：空缓存目录 → 全回落。
                let emptySource = SidecarPageTextSource(
                    store: store, cache: ExtractionTextCache(directory: dir.appendingPathComponent("text-cache-miss")))
                try assertRowsEqual(try emptySource.pages(rowIDs: rowIDs), direct, "state-miss")

                // 态3 哈希不符：条目键不是本书指纹（内容寻址查无此件）。
                let wrongSHA = String(repeating: "e", count: 64)
                let wrongDir = dir.appendingPathComponent("text-cache-wrongsha")
                try ExtractionTextCache(directory: wrongDir)
                    .store(fileSHA256: wrongSHA, extraction)
                let wrongSource = SidecarPageTextSource(
                    store: store, cache: ExtractionTextCache(directory: wrongDir))
                try assertRowsEqual(try wrongSource.pages(rowIDs: rowIDs), direct, "state-hash-mismatch")

                // 态4 版本不符：条目 normalizationVersion ≠ 期望 → 键内校验拒收。
                let badDir = dir.appendingPathComponent("text-cache-badver")
                let bucket = badDir.appendingPathComponent(String(book.fingerprint.prefix(2)))
                try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
                let key = try expectNotNil(ExtractionTextCache.cacheKey(sourceSHA256: book.fingerprint))
                let entryJSON = """
                {"format":"lit-text-cache","cacheFormatVersion":\(ExtractionTextCache.cacheFormatVersion),
                 "normalizationVersion":\(IndexStore.expectedNormalizationVersion + 1),
                 "sourceSHA256":"\(book.fingerprint)","fileSize":null,"pageCount":2,
                 "createdAt":"2026-10-07T00:00:00Z","pages":[]}
                """
                try Data(entryJSON.utf8).write(to: bucket.appendingPathComponent(key))
                let badVerSource = SidecarPageTextSource(
                    store: store, cache: ExtractionTextCache(directory: badDir))
                try assertRowsEqual(try badVerSource.pages(rowIDs: rowIDs), direct, "state-version-mismatch")
            },

            TestDesc(suite: "PageTextSource", name: "sidecarPreservesInputOrderAndSkipsMissing") {
                let dir = Fixtures.makeTempDir("pts-order")
                defer { Fixtures.cleanup(dir) }
                let (store, book, rowIDs) = try await indexedStoreAndRowIDs(dir)
                let shuffled = rowIDs.reversed() + ["999999", "not-a-number"]
                let cacheDir = dir.appendingPathComponent("text-cache")
                let cache = ExtractionTextCache(directory: cacheDir)
                let extraction = try PDFTextExtractor.extract(url: dir.appendingPathComponent("bookA.pdf"))
                try cache.store(fileSHA256: book.fingerprint, extraction)
                let source = SidecarPageTextSource(store: store, cache: cache)
                let viaSidecar = try source.pages(rowIDs: Array(shuffled))
                let direct = try store.pages(rowIDs: Array(shuffled))
                try assertRowsEqual(viaSidecar, direct, "ordered")
                try expectTrue(viaSidecar.contains { $0.textOriginal.contains("导论") },
                               "served rows must carry real page text")
            },
        ]
    }
}
