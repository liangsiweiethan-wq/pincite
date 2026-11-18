import Foundation
@testable import LiteratureCore

// MARK: - 更新 抽取文本缓存测试

enum ExtractionTextCacheSuite {
    static func makeCache() -> (ExtractionTextCache, URL) {
        let dir = Fixtures.makeTempDir("text-cache")
        return (ExtractionTextCache(directory: dir.appendingPathComponent("text-cache")),
                dir)
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "ExtractionTextCache", name: "missExtractStoreHitRoundTripEqualsPlainExtract") {
                let (cache, root) = makeCache()
                defer { Fixtures.cleanup(root) }
                let pdf = Fixtures.makePDF(pages: [.init(lines: ["缓存往返 一致性校验 Café ß"])], in: root, named: "c.pdf")
                let plain = try PDFTextExtractor.extract(url: pdf)
                let sha = try Fingerprint.sha256Hex(ofFileAt: pdf)
                try expectNil(cache.result(fileSHA256: sha), "cold cache misses")
                let viaCache = try PDFTextExtractor.extract(url: pdf, limits: .init(),
                                                             cache: cache, precomputedSHA256: sha)
                // 错键前缀取真键首字符的互补位——原写法硬置 "0"，sha 恰以 "0"
                // 开头时错键≡真键（1/16 概率抽签式必红，门禁第 3 轮实证），
                // 命中刚存条目。互补位可证恒异。
                let wrongKey = (sha.hasPrefix("0") ? "1" : "0") + String(sha.dropFirst())
                try expectTrue(wrongKey != sha, "mutated key must differ")
                try expectNil(cache.result(fileSHA256: wrongKey), "wrong key misses")
                let hit = try expectNotNil(cache.result(fileSHA256: sha), "stored entry hits")
                try expectEqual(hit.pageCount, plain.pageCount)
                try expectEqual(hit.pages.count, plain.pages.count)
                let a = plain.pages[0], b = hit.pages[0]
                try expectEqual(a.physicalPage, b.physicalPage)
                try expectEqual(a.label, b.label)
                try expectEqual(a.printedPage, b.printedPage)
                try expectEqual(a.text, b.text)
                try expectEqual(a.normalized.text, b.normalized.text)
                try expectEqual(a.normalized.starts, b.normalized.starts)
                try expectEqual(a.normalized.ends, b.normalized.ends)
                // 二次抽取走缓存：输出与首抽等值（同一结果路径）。
                let again = try PDFTextExtractor.extract(url: pdf, limits: .init(),
                                                         cache: cache, precomputedSHA256: sha)
                try expectEqual(again.pages[0].normalized.text, plain.pages[0].normalized.text)
            },

            TestDesc(suite: "ExtractionTextCache", name: "changedSourceHashMisses") {
                let (cache, root) = makeCache()
                defer { Fixtures.cleanup(root) }
                let pdf = Fixtures.makePDF(pages: [.init(lines: ["version one"])], in: root, named: "v.pdf")
                let sha1 = try Fingerprint.sha256Hex(ofFileAt: pdf)
                _ = try PDFTextExtractor.extract(url: pdf, limits: .init(), cache: cache, precomputedSHA256: sha1)
                try expectNotNil(cache.result(fileSHA256: sha1))
                // 覆写同一路径 → sha 变 → 旧键 miss、新键独立。
                try Data("overwritten — no longer a pdf".utf8).write(to: pdf)
                let sha2 = try Fingerprint.sha256Hex(ofFileAt: pdf)
                try expectNotEqual(sha1, sha2)
                try expectNotNil(cache.result(fileSHA256: sha1), "old entry untouched (content-addressed)")
                try expectNil(cache.result(fileSHA256: sha2), "new content misses")
            },

            TestDesc(suite: "ExtractionTextCache", name: "cacheKeyBindsNormAndFormatVersions") {
                let key = try expectNotNil(ExtractionTextCache.cacheKey(
                    sourceSHA256: String(repeating: "a", count: 64)))
                try expectTrue(key.contains(".v\(IndexStore.expectedNormalizationVersion)."),
                               "key binds normalization version: \(key)")
                try expectTrue(key.contains(".cf\(ExtractionTextCache.cacheFormatVersion).json"),
                               "key binds cache format version: \(key)")
                try expectNil(ExtractionTextCache.cacheKey(sourceSHA256: "short"),
                              "non-sha256 input yields nil key")
            },

            TestDesc(suite: "ExtractionTextCache", name: "corruptCacheEntryFailsOpen") {
                let (cache, root) = makeCache()
                defer { Fixtures.cleanup(root) }
                let sha = String(repeating: "b", count: 64)
                let bucket = root.appendingPathComponent("text-cache/\(String(sha.prefix(2)))")
                try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
                let entryURL = bucket.appendingPathComponent(
                    "\(sha).v\(IndexStore.expectedNormalizationVersion).cf\(ExtractionTextCache.cacheFormatVersion).json")
                try Data("{\"format\":\"lit-text-cache\",\"pages\":[{\"physicalPage\"".utf8).write(to: entryURL)
                try expectNil(cache.result(fileSHA256: sha), "truncated JSON misses, never throws")
                // 三元校验：format 对但 normVersion 不符 → miss。
                let wrong = """
                {"format":"lit-text-cache","cacheFormatVersion":\(ExtractionTextCache.cacheFormatVersion),
                 "normalizationVersion":\(IndexStore.expectedNormalizationVersion + 1),
                 "sourceSHA256":"\(sha)","pageCount":1,"createdAt":"2026-10-07T00:00:00Z",
                 "pages":[{"physicalPage":1,"label":null,"printedPage":null,"text":"t","normText":"t",
                 "normStartsB64":"","normEndsB64":""}]}
                """
                try Data(wrong.utf8).write(to: entryURL)
                try expectNil(cache.result(fileSHA256: sha), "normVersion mismatch misses")
            },

            TestDesc(suite: "ExtractionTextCache", name: "bucketLayoutByHashPrefix") {
                let (cache, root) = makeCache()
                defer { Fixtures.cleanup(root) }
                let sha = String(repeating: "cd", count: 32)
                let key = try expectNotNil(ExtractionTextCache.cacheKey(sourceSHA256: sha))
                try cache.store(fileSHA256: sha, PDFExtractionResult(pageCount: 0, pages: []))
                let expected = root.appendingPathComponent("text-cache")
                    .appendingPathComponent(String(sha.prefix(2)))
                    .appendingPathComponent(key)
                try expectTrue(FileManager.default.fileExists(atPath: expected.path),
                               "cache file lands in hash-prefix bucket: \(expected.path)")
                try expectTrue(cache.totalBytes() > 0)
                try cache.clear()
                try expectEqual(cache.totalBytes(), 0, "clear empties cache")
            },

            TestDesc(suite: "ExtractionTextCache", name: "precomputedSHAAvoidsRehash") {
                let (cache, root) = makeCache()
                defer { Fixtures.cleanup(root) }
                let pdf = Fixtures.makePDF(pages: [.init(lines: ["hash once"])], in: root, named: "h.pdf")
                let sha = try Fingerprint.sha256Hex(ofFileAt: pdf)   // 首算（进入 stat 门控缓存）
                _ = try PDFTextExtractor.extract(url: pdf, limits: .init(), cache: cache, precomputedSHA256: sha)
                // 同路径再取指纹：size/mtime 未变 → 缓存直出（桩语义：同值）。
                let shaAgain = try Fingerprint.sha256Hex(ofFileAt: pdf)
                try expectEqual(shaAgain, sha)
                // 缓存引擎对同 key 二次抽取直接命中（不再触 extract 主循环）。
                let hit = try expectNotNil(cache.result(fileSHA256: sha))
                try expectEqual(hit.pages.count, 1)
            },
        ]
    }
}
