import Foundation
@testable import LiteratureCore

enum ExclusionSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "Exclusion", name: "configuredIdentifierExcludesBookAndDerivatives") {
                let dir = Fixtures.makeTempDir("excl")
                defer { Fixtures.cleanup(dir) }
                let policy = ExclusionPolicy(config: ExclusionConfig(excludedIdentifiers: ["BOOK-0001"]))
                let book = dir.appendingPathComponent("BOOK-0001.pdf")
                try expectEqual(policy.evaluate(candidateFileURL: book, rootURL: dir),
                                .excludedByPathSubstring("BOOK-0001"))
                let derivative = dir.appendingPathComponent("BOOK-0001-v2.pdf")
                try expectEqual(policy.evaluate(candidateFileURL: derivative, rootURL: dir),
                                .excludedByPathSubstring("BOOK-0001"))
                let sub = dir.appendingPathComponent("nested/BOOK-0001-extract.pdf")
                try expectEqual(policy.evaluate(candidateFileURL: sub, rootURL: dir),
                                .excludedByPathSubstring("BOOK-0001"))
            },
            TestDesc(suite: "Exclusion", name: "configuredPathSubstringExcludes") {
                let dir = Fixtures.makeTempDir("excl-sub")
                defer { Fixtures.cleanup(dir) }
                let policy = ExclusionPolicy(config: ExclusionConfig(excludedPathSubstrings: ["private-notes"]))
                try expectEqual(policy.evaluate(candidateFileURL: dir.appendingPathComponent("private-notes-draft.pdf"), rootURL: dir),
                                .excludedByPathSubstring("private-notes"))
                try expectEqual(policy.evaluate(candidateFileURL: dir.appendingPathComponent("normal.pdf"), rootURL: dir), .allowed)
            },
            TestDesc(suite: "Exclusion", name: "configuredGlobExcludes") {
                let dir = Fixtures.makeTempDir("excl-glob")
                defer { Fixtures.cleanup(dir) }
                let policy = ExclusionPolicy(config: ExclusionConfig(excludedGlobs: ["drafts/*"]))
                try expectEqual(policy.evaluate(candidateFileURL: dir.appendingPathComponent("drafts/wip.pdf"), rootURL: dir),
                                .excludedByGlob("drafts/*"))
                try expectEqual(policy.evaluate(candidateFileURL: dir.appendingPathComponent("final.pdf"), rootURL: dir), .allowed)
            },
            TestDesc(suite: "Exclusion", name: "symlinkEscapeRejected") {
                let root = Fixtures.makeTempDir("excl-sym-root")
                defer { Fixtures.cleanup(root) }
                let outside = Fixtures.makeTempDir("excl-sym-outside")
                defer { Fixtures.cleanup(outside) }
                let outsidePDF = Fixtures.makePDF(pages: [.init(lines: ["outside"])], in: outside, named: "secret.pdf")
                let escaping = Fixtures.makeSymlink(to: outsidePDF, in: root, named: "escape.pdf")
                let policy = ExclusionPolicy()
                try expectEqual(policy.evaluate(candidateFileURL: escaping, rootURL: root), .symlinkEscape)
                let insidePDF = Fixtures.makePDF(pages: [.init(lines: ["inside"])], in: root, named: "real.pdf")
                let alias = Fixtures.makeSymlink(to: insidePDF, in: root, named: "alias.pdf")
                try expectEqual(policy.evaluate(candidateFileURL: alias, rootURL: root), .allowed)
                let pathRule = ExclusionPolicy(config: ExclusionConfig(excludedPathSubstrings: ["real.pdf"]))
                try expectEqual(pathRule.evaluate(candidateFileURL: alias, rootURL: root),
                                .excludedByPathSubstring("real.pdf"))
                let globRule = ExclusionPolicy(config: ExclusionConfig(excludedGlobs: ["real.pdf"]))
                try expectEqual(globRule.evaluate(candidateFileURL: alias, rootURL: root),
                                .excludedByGlob("real.pdf"))
            },
            TestDesc(suite: "Exclusion", name: "nonPDFRejected") {
                let dir = Fixtures.makeTempDir("excl-type")
                defer { Fixtures.cleanup(dir) }
                try expectEqual(ExclusionPolicy().evaluate(candidateFileURL: dir.appendingPathComponent("notes.txt"), rootURL: dir),
                                .unsupportedFileType)
            },
            TestDesc(suite: "Exclusion", name: "configuredBookIDExclusion") {
                let policy = ExclusionPolicy(config: ExclusionConfig(excludedBookIDs: ["OTHER-999"]))
                try expectEqual(policy.evaluateBookID("bOTHER-999-derived"), .excludedByID("OTHER-999"))
                try expectEqual(policy.evaluateBookID("b12345678901234567890"), .allowed)
            },
            TestDesc(suite: "Exclusion", name: "enginePurgesExcludedByID") {
                let dir = Fixtures.makeTempDir("excl-engine")
                defer { Fixtures.cleanup(dir) }
                let pdf = Fixtures.makePDF(pages: [.init(lines: ["some content 内容"])], in: dir, named: "a.pdf")
                let store = try Fixtures.openStore(in: dir)
                var summary = try await IndexingEngine(store: store, policy: ExclusionPolicy()).run(rootURL: dir)
                try expectEqual(summary.indexedNew, 1)
                let books = try store.allBooks()
                try expectEqual(books.count, 1)
                let restrictive = ExclusionPolicy(config: ExclusionConfig(excludedPathSubstrings: [books[0].fileName]))
                summary = try await IndexingEngine(store: store, policy: restrictive).run(rootURL: dir)
                try expectEqual(summary.excluded, 1)
                let after = try store.allBooks().filter { $0.realPath == pdf.resolvingSymlinksInPath().path }
                try expectTrue(after.isEmpty, "previously indexed book must be purged once excluded")
            },
            TestDesc(suite: "Exclusion", name: "escapingAliasDoesNotPurgeOtherLibrary") {
                let root = Fixtures.makeTempDir("alias-library")
                defer { Fixtures.cleanup(root) }
                let outside = Fixtures.makeTempDir("indexed-library")
                defer { Fixtures.cleanup(outside) }
                let pdf = Fixtures.makePDF(pages: [.init(lines: ["sample passage"])], in: outside, named: "sample.pdf")
                let store = try Fixtures.openStore(in: root)
                let engine = IndexingEngine(store: store, policy: ExclusionPolicy())
                _ = try await engine.run(rootURL: outside)
                let original = try expectNotNil(try store.allBooks().first)
                _ = Fixtures.makeSymlink(to: pdf, in: root, named: "alias.pdf")
                let result = try await engine.run(rootURL: root)
                try expectEqual(result.excluded, 1)
                try expectEqual(try store.allBooks().map(\.id), [original.id])
            },
        ]
    }
}
