import Foundation
@testable import LiteratureCore

enum IncrementalSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "Incremental", name: "unavailableLibraryPreservesIndex") {
                let dir = Fixtures.makeTempDir("unavailable-library")
                defer { Fixtures.cleanup(dir) }
                let library = dir.appendingPathComponent("library", isDirectory: true)
                let moved = dir.appendingPathComponent("unmounted", isDirectory: true)
                try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
                Fixtures.makePDF(pages: [.init(lines: ["sample passage"])], in: library, named: "sample.pdf")
                let store = try Fixtures.openStore(in: dir)
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                _ = try await engine.run(rootURL: library)
                try FileManager.default.moveItem(at: library, to: moved)
                try await expectThrowsAsync { try await engine.run(rootURL: library) }
                let book = try expectNotNil(try store.allBooks().first)
                try expectEqual(try store.pageCount(bookID: book.id), 1)
            },
            TestDesc(suite: "Incremental", name: "identicalCopiesKeepSeparateBookIDs") {
                let dir = Fixtures.makeTempDir("identical-copies")
                defer { Fixtures.cleanup(dir) }
                let first = Fixtures.makePDF(pages: [.init(lines: ["sample passage"])], in: dir, named: "first.pdf")
                let second = dir.appendingPathComponent("second.pdf")
                try FileManager.default.copyItem(at: first, to: second)
                let store = try Fixtures.openStore(in: dir)
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                let explicit = try await engine.indexExplicitFiles(urls: [first, second])
                try expectEqual(explicit.indexedNew, 2)
                let books = try store.allBooks()
                try expectEqual(Set(books.map(\.fileName)), Set(["first.pdf", "second.pdf"]))
                try expectEqual(Set(books.map(\.id)).count, 2)
                try expectEqual(Set(books.map(\.fingerprint)).count, 1)
                let rescan = try await engine.run(rootURL: dir)
                try expectEqual(rescan.skippedUnchanged, 2)
            },
            TestDesc(suite: "Incremental", name: "fingerprintChangesWhenSizeAndMtimeMatch") {
                let dir = Fixtures.makeTempDir("fingerprint-mtime")
                defer { Fixtures.cleanup(dir) }
                let url = dir.appendingPathComponent("sample.pdf")
                let mtime = Date(timeIntervalSince1970: 1_700_000_000)
                try Data("aaaa".utf8).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
                let before = try Fingerprint.sha256Hex(ofFileAt: url)
                try Data("bbbb".utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
                try expectNotEqual(try Fingerprint.sha256Hex(ofFileAt: url), before)
            },
            TestDesc(suite: "Incremental", name: "failedPageWriteRollsBackBookAndFingerprint") {
                let dir = Fixtures.makeTempDir("atomic-index")
                defer { Fixtures.cleanup(dir) }
                Fixtures.makePDF(pages: [.init(lines: ["sample passage"])], in: dir, named: "sample.pdf")
                let store = try Fixtures.openStore(in: dir)
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                _ = try await engine.run(rootURL: dir)
                let original = try expectNotNil(try store.allBooks().first)
                let page = try expectNotNil(try store.page(bookID: original.id, pageNumber: 1))
                var changed = original
                changed.fingerprint = "replacement-fingerprint"
                try expectThrows(try store.saveIndexedBook(changed, pages: [page, page]))
                try expectEqual(try store.book(byID: original.id)?.fingerprint, original.fingerprint)
                try expectEqual(try store.page(bookID: original.id, pageNumber: 1)?.textOriginal, page.textOriginal)
            },
            TestDesc(suite: "Incremental", name: "unchangedCorruptFileStillFails") {
                let dir = Fixtures.makeTempDir("inc-failed")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                try Data("not a PDF".utf8).write(to: dir.appendingPathComponent("corrupt.pdf"))
                let first = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let second = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                try expectEqual(first.failed, 1)
                try expectEqual(second.failed, 1)
                try expectEqual(second.skippedUnchanged, 0)
            },
            TestDesc(suite: "Incremental", name: "secondRunSkipsUnchanged") {
                let dir = Fixtures.makeTempDir("inc")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                Fixtures.makePDF(pages: [.init(lines: ["content one 内容"])], in: dir, named: "a.pdf")
                let first = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                try expectEqual(first.indexedNew, 1)
                let second = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                try expectEqual(second.skippedUnchanged, 1)
                try expectEqual(second.indexedNew, 0)
                try expectEqual(second.updated, 0)
                let book = try expectNotNil(try store.allBooks().first)
                try expectEqual(try store.pageCount(bookID: book.id), 1, "no duplicate pages")
            },
            TestDesc(suite: "Incremental", name: "changedFileIsReindexedUnderSameBookID") {
                let dir = Fixtures.makeTempDir("inc-update")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let pdf = Fixtures.makePDF(pages: [.init(lines: ["original text 原文"])], in: dir, named: "a.pdf")
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let bookBefore = try expectNotNil(try store.allBooks().first)
                let hitBefore = try SearchService(store: store).search("original")
                try expectEqual(hitBefore.count, 1)

                try SyntheticPDFMaker.write(pages: [.init(lines: ["replacement text 替换"])], to: pdf)
                let summary = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                try expectEqual(summary.updated, 1)

                let bookAfter = try expectNotNil(try store.allBooks().first)
                try expectEqual(bookAfter.id, bookBefore.id, "book identity survives content updates")
                try expectNotEqual(bookAfter.fingerprint, bookBefore.fingerprint, "fingerprint must change with content")

                let service = SearchService(store: store)
                try expectEqual(try service.search("original").count, 0, "old text gone")
                let newHits = try service.search("替换")
                try expectEqual(newHits.count, 1)
                try expectEqual(newHits[0].fingerprint, bookAfter.fingerprint)
            },
            TestDesc(suite: "Incremental", name: "deletedFileIsRemovedFromIndex") {
                let dir = Fixtures.makeTempDir("inc-delete")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let pdf = Fixtures.makePDF(pages: [.init(lines: ["doomed text 消失"])], in: dir, named: "gone.pdf")
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                try expectEqual(try store.allBooks().count, 1)
                try FileManager.default.removeItem(at: pdf)
                let summary = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                try expectEqual(summary.removed, 1)
                try expectEqual(try store.allBooks().count, 0)
                try expectEqual(try SearchService(store: store).search("消失").count, 0)
            },
            TestDesc(suite: "Incremental", name: "pageNumbersAreBoundToFingerprint") {
                let dir = Fixtures.makeTempDir("inc-fp")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let pdf = Fixtures.makePDF(pages: [
                    .init(lines: ["page one text"]),
                    .init(lines: ["page two 目标词"]),
                ], in: dir, named: "multi.pdf")
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let before = try expectNotNil(try store.allBooks().first)
                let hit = try expectNotNil(try SearchService(store: store).search("目标词").first)
                try expectEqual(hit.fingerprint, before.fingerprint)
                try expectEqual(hit.physicalPage, 2)

                try SyntheticPDFMaker.write(pages: [.init(lines: ["totally different"])], to: pdf)
                _ = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                let after = try expectNotNil(try store.allBooks().first)
                try expectNotEqual(after.fingerprint, hit.fingerprint, "old hit is stale by definition")
                try expectEqual(try SearchService(store: store).search("目标词").count, 0)
            },
            TestDesc(suite: "Incremental", name: "cancellationStopsBetweenFiles") {
                let dir = Fixtures.makeTempDir("inc-cancel")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                for i in 0..<5 {
                    Fixtures.makePDF(pages: [.init(lines: ["book number \(i) 第\(i)册"])], in: dir, named: "b\(i).pdf")
                }
                // Deterministic cancellation: cancel the run's Task as soon as
                // the first file has been processed; the engine must honour it
                // between files.
                final class CancelBox: @unchecked Sendable {
                    let lock = NSLock()
                    var task: Task<IndexRunSummary, Error>?
                    func cancel() {
                        lock.lock(); defer { lock.unlock() }
                        task?.cancel()
                    }
                    func clear() {
                        lock.lock(); defer { lock.unlock() }
                        task = nil
                    }
                }
                let box = CancelBox()
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy()) { progress in
                    if progress.phase == .indexing && progress.filesDone >= 1 {
                        box.cancel()
                    }
                }
                let task = Task { try await engine.run(rootURL: dir) }
                box.lock.withLock { box.task = task }
                let summary = try await task.value
                box.clear()
                try expectTrue(summary.wasCancelled)
                try expectTrue(summary.filesDone < 5, "cancellation must leave files unprocessed")
            },
        ]
    }
}
