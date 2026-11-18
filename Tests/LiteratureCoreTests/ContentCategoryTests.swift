import Foundation
@testable import LiteratureCore

// 内容类别分类测试。路径归类由 ContentCategoryFolders.current 里的
// 文件夹名决定；测试在每个用到它的用例里显式设置并复原，永不依赖
// 进程静态默认值泄漏到其他套件。
enum ContentCategorySuite {
    static var tests: [TestDesc] {
        var t: [TestDesc] = []
        t.append(TestDesc(suite: "ContentCategory", name: "classifyPathRulesFourCategories") {
            try Self.withFolders {
                try expectTrue(classifyContentCategory(path: "/Users/example/Library/Books/张三/某书.pdf", title: "某书") == "著作")
                try expectTrue(classifyContentCategory(path: "/Users/example/Library/Papers/李四/某论文.pdf", title: "某论文") == "论文")
                try expectTrue(classifyContentCategory(path: "/Users/example/Library/Entries/x/y.pdf", title: "词条") == "词条")
            }
        })
        t.append(TestDesc(suite: "ContentCategory", name: "toolbookLexiconBeatsPathPriority") {
            try Self.withFolders {
                // A toolbook stays a toolbook even under Books/ (lexicon beats path rules).
                try expectTrue(classifyContentCategory(path: "/Users/example/Library/Books/示例引注手册编写组/示例引注手册（第二版）.pdf",
                                                       title: "示例引注手册（第二版）") == "工具书")
                try expectTrue(classifyContentCategory(path: "/Users/example/Library/Books/示例译名室/示例翻译大辞典.pdf",
                                                       title: "示例翻译大辞典") == "工具书")
            }
        })
        t.append(TestDesc(suite: "ContentCategory", name: "conversationNeverToolbook") {
            try Self.withFolders {
                try expectTrue(classifyContentCategory(path: "/Users/example/Library/Conversations/sample/x.pdf", title: "AI 会话记录（草稿）") == "")
            }
        })
        t.append(TestDesc(suite: "ContentCategory", name: "searchFilterToolbookToggle") {
            try expectTrue(searchShouldInclude(category: "著作", includeToolBooks: false))
            try expectTrue(searchShouldInclude(category: "", includeToolBooks: false))    // 未知 fail-open
            try expectFalse(searchShouldInclude(category: "工具书", includeToolBooks: false))
            try expectTrue(searchShouldInclude(category: "工具书", includeToolBooks: true))
        })
        t.append(TestDesc(suite: "ContentCategory", name: "migrationV12BackfillsProductionPaths") {
            try Self.withFolders {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lit-cc-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { Fixtures.cleanup(dir) }
                let store = try IndexStore(path: dir.appendingPathComponent("index.db"))
                try store.upsertBook(IndexStore.BookRow(
                    id: "cc1", realPath: "/Users/example/Library/Books/某作者/某著作.pdf", rootPath: "/Users/example/Library/Books",
                    relPath: "某著作.pdf", fileName: "某著作.pdf", firstFingerprint: "fp1",
                    fingerprint: "fp1", fileSize: 1, mtime: 0, pageCount: 1, status: "ok", indexedAt: 0))
                let stmt = try store.db.prepare("SELECT content_category FROM books WHERE id = ?;")
                try stmt.bindText(1, "cc1")
                guard try stmt.step() else { try failTest("行不存在") }
                try expectTrue(stmt.text(0) == "著作", "回填类别: \(stmt.text(0))")
            }
        })
        t.append(TestDesc(suite: "ContentCategory", name: "publisherNameIsNotToolbook") {
            try Self.withFolders {
                try expectTrue(classifyContentCategory(
                    path: "/Users/example/Library/Books/Avery Quill/sample-one.pdf",
                    title: "Avery Quill, A Sample Treatise, Example Press, 2001.pdf") == "著作")
                try expectTrue(classifyContentCategory(
                    path: "/Users/example/Library/Books/Jordan Marlowe/sample-two.pdf",
                    title: "Jordan Marlowe, Notes on Fictional Subjects, Sample House, 2002.pdf") == "著作")
            }
        })
        t.append(TestDesc(suite: "ContentCategory", name: "chainVersionIsThirteen") {
            try expectTrue(IndexStore.currentSchemaVersion == 13)
        })
        return t
    }

    static func withFolders(_ body: () throws -> Void) throws {
        let saved = ContentCategoryFolders.current
        ContentCategoryFolders.current = .init(books: ["Books"], papers: ["Papers"], entries: ["Entries"])
        defer { ContentCategoryFolders.current = saved }
        try body()
    }
}
