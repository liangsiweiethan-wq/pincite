import Foundation
@testable import LiteratureCore

/// Shared synthetic-only fixture helpers. No real books, no OCR, no network.
enum Fixtures {
    static func makeTempDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("litsearch-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func makePDF(pages: [SyntheticPDFPage], in dir: URL, named name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        do {
            try SyntheticPDFMaker.write(pages: pages, to: url)
        } catch {
            fatalError("fixture generation failed: \(error)")
        }
        return url
    }

    static func makeRawFile(_ bytes: Data, in dir: URL, named name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        try! bytes.write(to: url)
        return url
    }

    static func makeSymlink(to target: URL, in dir: URL, named name: String) -> URL {
        let link = dir.appendingPathComponent(name)
        try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return link
    }

    static func openStore(in dir: URL, options: IndexStore.Options = .init()) throws -> IndexStore {
        try IndexStore(path: dir.appendingPathComponent("index.db"), options: options)
    }

    static func copyForReadOnlyReplica(dbURL: URL, into replicaDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: replicaDir, withIntermediateDirectories: true)
        try fm.copyItem(at: dbURL, to: replicaDir.appendingPathComponent("index.db"))
        let ft = dbURL.deletingLastPathComponent().appendingPathComponent("fulltext.db")
        if fm.fileExists(atPath: ft.path) {
            try fm.copyItem(at: ft, to: replicaDir.appendingPathComponent("fulltext.db"))
        }
        for name in ["index.db", "fulltext.db"] {
            let url = replicaDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            let db = try SQLiteDatabase(path: url.path)
            try db.exec("PRAGMA journal_mode=DELETE;")
        }
    }

    static func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}
