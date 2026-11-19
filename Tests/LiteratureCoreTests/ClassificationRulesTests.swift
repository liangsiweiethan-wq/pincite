import Foundation
@testable import LiteratureCore

// MARK: - 自动归类规则版套件

enum ClassificationRulesSuite {

    static func makeBook(_ id: String, title: String?, author: String?,
                         relPath: String? = nil, realPath: String? = nil) -> IndexStore.BookRow {
        IndexStore.BookRow(
            id: id, realPath: realPath ?? "/Papers/\(relPath ?? "\(id).pdf")",
            rootPath: "/Papers",
            relPath: relPath ?? "\(id).pdf", fileName: (relPath ?? "\(id).pdf"),
            title: title, author: author, version: nil, language: nil, metaSource: nil,
            firstFingerprint: "fp-\(id)", fingerprint: "fp-\(id)", fileSize: 100, mtime: 0,
            pageCount: 1, status: "ok", error: nil, indexedAt: 0)
    }

    static func rule(_ name: String, _ match: String, _ algo: ClassificationAlgorithm,
                     _ target: String, enabled: Bool = true, position: Int = 0,
                     id: Int64 = 1) -> ClassificationRule {
        ClassificationRule(id: id, name: name, matchText: match, algorithm: algo,
                           targetCategory: target, enabled: enabled, position: position)
    }

    static var tests: [TestDesc] {
        [
            // ── any 档：词集任一 contains（大小写不敏感）──
            TestDesc(suite: "ClassificationRules", name: "anyAlgorithmHitAndMiss") {
                let r = rule("数学", "林克尔 泛函", .any, "数学")
                let hit = makeBook("b1", title: "泛函示例", author: "示例 林克尔")
                try expectTrue(ClassificationRulesStore.matches(rule: r, book: hit))
                let miss = makeBook("b2", title: "契约法总论", author: "某作者")
                try expectFalse(ClassificationRulesStore.matches(rule: r, book: miss))
                // 大小写不敏感
                let eng = rule("拓扑", "芒克斯", .any, "拓扑")
                try expectTrue(ClassificationRulesStore.matches(
                    rule: eng, book: makeBook("b3", title: "示例拓扑", author: "示例·芒克斯")))
                // 空词集不命中（不猜）
                let empty = rule("空", "   ", .any, "未定")
                try expectFalse(ClassificationRulesStore.matches(rule: empty, book: hit))
            },

            // ── any 档 NULL：title+author 全 NULL 不命中 ──
            TestDesc(suite: "ClassificationRules", name: "anyUnknownFieldsNeverMatch") {
                let r = rule("数学", "林克尔", .any, "数学")
                let unknownBook = makeBook("b4", title: nil, author: nil)
                try expectFalse(ClassificationRulesStore.matches(rule: r, book: unknownBook))
                // 单字段 NULL：另一字段可参与
                let titleOnly = makeBook("b5", title: "林克尔方程", author: nil)
                try expectTrue(ClassificationRulesStore.matches(rule: r, book: titleOnly))
            },

            // ── exact 档：字段等值与大小写；无效形态不猜 ──
            TestDesc(suite: "ClassificationRules", name: "exactFieldValueEquality") {
                let t = rule("书名等值", "title=计算理论导论", .exact, "理论")
                try expectTrue(ClassificationRulesStore.matches(
                    rule: t, book: makeBook("b1", title: "计算理论导论", author: nil)))
                try expectFalse(ClassificationRulesStore.matches(
                    rule: t, book: makeBook("b2", title: "计算理论导论（第二版）", author: nil)))
                // 大小写不敏感
                let a = rule("作者等值", "author=示例 林克尔", .exact, "译著")
                try expectTrue(ClassificationRulesStore.matches(
                    rule: a, book: makeBook("b3", title: nil, author: "示例 林克尔")))
                // 无效形态（无 = / 未知字段 / 空值）不命中不猜
                let invalid1 = rule("坏1", "计算理论", .exact, "理论")
                try expectFalse(ClassificationRulesStore.matches(rule: invalid1, book: makeBook("b1", title: "计算理论导论", author: nil)))
                let invalid2 = rule("坏2", "year=2000", .exact, "理论")
                try expectFalse(ClassificationRulesStore.matches(rule: invalid2, book: makeBook("b1", title: "计算理论导论", author: nil)))
                try expectTrue(ClassificationRulesStore.isInvalidRule(invalid1))
                try expectTrue(ClassificationRulesStore.isInvalidRule(invalid2))
                try expectFalse(ClassificationRulesStore.isInvalidRule(t))
                // 对应字段 NULL 不命中
                try expectFalse(ClassificationRulesStore.matches(
                    rule: t, book: makeBook("b9", title: nil, author: nil)))
            },

            // ── prefix_dir 档：路径段边界（/Papers 不中 /PapersX/）──
            TestDesc(suite: "ClassificationRules", name: "prefixDirSegmentBoundary") {
                let r = rule("论文目录", "/Papers/", .prefix_dir, "论文")
                let inside = makeBook("b1", title: nil, author: nil,
                                      relPath: "论文/某书.pdf", realPath: "/Papers/论文/某书.pdf")
                try expectTrue(ClassificationRulesStore.matches(rule: r, book: inside))
                // 段边界反例：论文X 不得被 /Papers/ 命中
                let tricky = makeBook("b2", title: nil, author: nil,
                                      relPath: "论文X/书.pdf", realPath: "/PapersX/书.pdf")
                try expectFalse(ClassificationRulesStore.matches(rule: r, book: tricky))
                // 无尾斜杠前缀仍守住段边界（rel_path 段首匹配）
                let bare = rule("论文目录2", "/Papers", .prefix_dir, "论文")
                try expectTrue(ClassificationRulesStore.matches(rule: bare, book: inside))
                try expectFalse(ClassificationRulesStore.matches(rule: bare, book: tricky))
                // rel_path 降级处理（相对前缀匹配：库根挂载点漂移时仍命中）
                let relOnly = makeBook("b3", title: nil, author: nil,
                                       relPath: "论文/远书.pdf", realPath: "/Volumes/X/论文/远书.pdf")
                let relRule = rule("论文相对", "论文/", .prefix_dir, "论文")
                try expectTrue(ClassificationRulesStore.matches(rule: relRule, book: relOnly))
                try expectFalse(ClassificationRulesStore.matches(rule: relRule, book: tricky))
                // 空匹配文本不命中
                let empty = rule("空", "", .prefix_dir, "论文")
                try expectFalse(ClassificationRulesStore.matches(rule: empty, book: inside))
            },

            // ── 先中先得 + enabled=0 跳过 + position 决定顺序 ──
            TestDesc(suite: "ClassificationRules", name: "firstMatchWinsOrderAndEnabled") {
                let first = rule("规则一", "计算", .any, "先中", enabled: true, position: 0, id: 1)
                let second = rule("规则二", "计算", .any, "次中", enabled: true, position: 1, id: 2)
                let disabled = rule("禁用", "计算", .any, "不该中", enabled: false, position: -1, id: 3)
                let book = makeBook("b1", title: "计算理论", author: nil)
                let winner = ClassificationRulesStore.classify(book: book,
                                                               rules: [second, disabled, first])
                try expectEqual(winner?.id, first.id)
                try expectEqual(winner?.targetCategory, "先中")
                // 全禁用 → nil
                let off1 = rule("禁1", "计算", .any, "X", enabled: false, position: 0, id: 1)
                try expectNil(ClassificationRulesStore.classify(book: book, rules: [off1]))
            },

            // ── classifyAll：写表幂等 + 未归类删行 + 计数如实 ──
            TestDesc(suite: "ClassificationRules", name: "classifyAllIdempotentAndCounts") {
                let dir = Fixtures.makeTempDir("classify-all")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let rulesStore = ClassificationRulesStore(indexStore: store)
                try store.upsertBook(makeBook("b1", title: "泛函分析", author: "林克尔"))
                try store.upsertBook(makeBook("b2", title: "契约法", author: nil))
                let _ = try rulesStore.addRule(name: "数学", matchText: "泛函",
                                               algorithm: .any, targetCategory: "数学")
                let r1 = try rulesStore.classifyAll()
                try expectEqual(r1.classified, 1)
                try expectEqual(r1.unclassified, 1)
                var rows = try store.db.prepare("SELECT book_id, category FROM book_classifications;")
                var seen: [String: String] = [:]
                while try rows.step() { seen[rows.text(0)] = rows.text(1) }
                try expectEqual(seen, ["b1": "数学"])
                // 同书重跑：仍一行，classified_at 更新（幂等 upsert）
                let before = try store.db.prepare("SELECT classified_at FROM book_classifications WHERE book_id='b1';")
                _ = try before.step()
                let t1 = before.double(0)
                try await Task.sleep(nanoseconds: 20_000_000)
                let r2 = try rulesStore.classifyAll()
                try expectEqual(r2.classified, 1)
                rows = try store.db.prepare("SELECT count(*) FROM book_classifications;")
                _ = try rows.step()
                try expectEqual(rows.int(0), Int64(1))
                let after = try store.db.prepare("SELECT classified_at FROM book_classifications WHERE book_id='b1';")
                _ = try after.step()
                try expectTrue(after.double(0) >= t1)
                // 规则删除后重跑：旧分类行清除（书回未归类桶）
                try rulesStore.deleteRule(ids: [1])
                let r3 = try rulesStore.classifyAll()
                try expectEqual(r3.classified, 0)
                try expectEqual(r3.unclassified, 2)
                rows = try store.db.prepare("SELECT count(*) FROM book_classifications;")
                _ = try rows.step()
                try expectEqual(rows.int(0), Int64(0))
                try expectEqual(try rulesStore.unclassifiedCount(), 2)
            },

            // ── 阻塞项测试：归类×replacePages 并发互斥 ──
            // 事务段取 IndexStore.lock（lock+BEGIN 并用，replacePages 同款）
            // 后，两个写路径串行化：并发跑各自成功、无交叉回滚、数据一致。
            TestDesc(suite: "ClassificationRules", name: "classifyAllConcurrentWithReplacePages") {
                let dir = Fixtures.makeTempDir("classify-concurrent")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let rulesStore = ClassificationRulesStore(indexStore: store)
                // 拉长归类事务窗口：120 本书逐行 upsert
                for i in 0..<120 {
                    try store.upsertBook(makeBook("b\(i)", title: "并发书\(i)", author: nil))
                }
                _ = try rulesStore.addRule(name: "全部", matchText: "并发书",
                                           algorithm: .any, targetCategory: "并发桶")
                try store.upsertBook(makeBook("b-target", title: "换页目标书", author: nil))
                let target = IndexStore.BookRow(
                    id: "b-target", realPath: "/tmp/b-target.pdf", rootPath: "/tmp",
                    relPath: "b-target.pdf", fileName: "b-target.pdf",
                    title: "换页目标书v2", author: nil, version: nil, language: nil,
                    metaSource: nil, firstFingerprint: "fp2", fingerprint: "fp2",
                    fileSize: 1, mtime: 0, pageCount: 1, status: "ok", error: nil, indexedAt: 0)
                let pageRow = IndexStore.PageRow(bookID: "b-target", pageNumber: 1, label: nil,
                                                 printedPage: nil, textOriginal: "new page",
                                                 textNorm: "new page", normStarts: [0],
                                                 normEnds: [Int32("new page".count)])
                // 并发 8 路：偶数 classifyAll、奇数 replacePages，全部必须成功
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for i in 0..<8 {
                        group.addTask {
                            if i % 2 == 0 {
                                _ = try rulesStore.classifyAll()
                            } else {
                                try store.replacePages(bookID: "b-target", [pageRow])
                                _ = target
                            }
                        }
                    }
                    try await group.waitForAll()
                }
                // 终态一致：分类行齐（120 本「并发书」命中；b-target 不匹配
                // 规则本就不该有分类行）、pages 落地、无半态
                let classified = try store.db.prepare(
                    "SELECT count(*) FROM book_classifications;")
                _ = try classified.step()
                try expectEqual(classified.int(0), Int64(120))
                let pages = try store.db.prepare(
                    "SELECT count(*) FROM pages WHERE book_id='b-target' AND text_norm='new page';")
                _ = try pages.step()
                try expectEqual(pages.int(0), Int64(1))
                let ruleCount = try store.db.prepare(
                    "SELECT count(*) FROM classification_rules;")
                _ = try ruleCount.step()
                try expectEqual(ruleCount.int(0), Int64(1))
            },

            // ── 应修回归断言：孤儿行回收 + unclassifiedCount 差集 ──
            TestDesc(suite: "ClassificationRules", name: "orphanRowsReclaimedAndCountExact") {
                let dir = Fixtures.makeTempDir("classify-orphan")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let rulesStore = ClassificationRulesStore(indexStore: store)
                try store.upsertBook(makeBook("b-gone", title: "将删除的书", author: nil))
                try store.upsertBook(makeBook("b-stay", title: "留下的书", author: nil))
                _ = try rulesStore.addRule(name: "任意", matchText: "书",
                                           algorithm: .any, targetCategory: "全部")
                let first = try rulesStore.classifyAll()
                try expectEqual(first.classified, 2)
                // 删书（books 无外键——分类行残留为孤儿）
                try store.deleteBook(id: "b-gone")
                let orphanCount = try store.db.prepare(
                    "SELECT count(*) FROM book_classifications WHERE book_id='b-gone';")
                _ = try orphanCount.step()
                try expectEqual(orphanCount.int(0), Int64(1), "前置：孤儿行在位")
                // 重跑：孤儿行回收；计数按 books 差集直算不失真
                let second = try rulesStore.classifyAll()
                try expectEqual(second.classified, 1)
                let after = try store.db.prepare(
                    "SELECT count(*) FROM book_classifications WHERE book_id='b-gone';")
                _ = try after.step()
                try expectEqual(after.int(0), Int64(0), "孤儿行已被重跑回收")
                try expectEqual(try rulesStore.unclassifiedCount(), 0)
                // 全删规则后重跑：分类清零、未归类 = 在库书数（差集语义）
                try rulesStore.deleteRule(ids: [1])
                let third = try rulesStore.classifyAll()
                try expectEqual(third.classified, 0)
                try expectEqual(third.unclassified, 1)
                try expectEqual(try rulesStore.unclassifiedCount(), 1)
            },

            // ── dry-run：只算不写 ──
            TestDesc(suite: "ClassificationRules", name: "dryRunWritesNothing") {
                let dir = Fixtures.makeTempDir("classify-dry")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let rulesStore = ClassificationRulesStore(indexStore: store)
                try store.upsertBook(makeBook("b1", title: "泛函分析", author: nil))
                _ = try rulesStore.addRule(name: "数学", matchText: "泛函",
                                           algorithm: .any, targetCategory: "数学")
                let report = try rulesStore.classifyAll(dryRun: true)
                try expectEqual(report.classified, 1)
                try expectEqual(report.perBook?.count, 1)
                try expectEqual(report.perBook?.first?.category, "数学")
                let rows = try store.db.prepare("SELECT count(*) FROM book_classifications;")
                _ = try rows.step()
                try expectEqual(rows.int(0), Int64(0))
            },

            // ── 无效规则（exact 无字段前缀）跳过计数 ──
            TestDesc(suite: "ClassificationRules", name: "invalidRuleSkippedAndCounted") {
                let dir = Fixtures.makeTempDir("classify-invalid")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let rulesStore = ClassificationRulesStore(indexStore: store)
                try store.upsertBook(makeBook("b1", title: "泛函分析", author: nil))
                _ = try rulesStore.addRule(name: "坏规则", matchText: "泛函",
                                           algorithm: .exact, targetCategory: "数学")
                _ = try rulesStore.addRule(name: "好规则", matchText: "泛函",
                                           algorithm: .any, targetCategory: "数学", position: 1)
                let report = try rulesStore.classifyAll()
                try expectEqual(report.invalidSkipped, 1)
                try expectEqual(report.classified, 1)
                let rows = try store.db.prepare("SELECT category FROM book_classifications;")
                _ = try rows.step()
                try expectEqual(rows.text(0), "数学")
            },

            // ── disabled 计数 ──
            TestDesc(suite: "ClassificationRules", name: "disabledRulesCountedNotApplied") {
                let dir = Fixtures.makeTempDir("classify-disabled")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let rulesStore = ClassificationRulesStore(indexStore: store)
                try store.upsertBook(makeBook("b1", title: "泛函分析", author: nil))
                let rid = try rulesStore.addRule(name: "关", matchText: "泛函",
                                                 algorithm: .any, targetCategory: "数学")
                try rulesStore.setEnabled(id: rid, enabled: false)
                let report = try rulesStore.classifyAll()
                try expectEqual(report.disabledSkipped, 1)
                try expectEqual(report.classified, 0)
            },

            // ── 规则 CRUD 往返 + 上下移 ──
            TestDesc(suite: "ClassificationRules", name: "ruleCrudRoundTripAndMove") {
                let dir = Fixtures.makeTempDir("classify-crud")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let rulesStore = ClassificationRulesStore(indexStore: store)
                let idA = try rulesStore.addRule(name: "A", matchText: "a",
                                                 algorithm: .any, targetCategory: "甲")
                let idB = try rulesStore.addRule(name: "B", matchText: "title=b",
                                                 algorithm: .exact, targetCategory: "乙")
                var rules = try rulesStore.rules()
                try expectEqual(rules.count, 2)
                try expectEqual(rules[0].name, "A")
                try expectEqual(rules[1].algorithm, ClassificationAlgorithm.exact)
                // 上移 B → B 在前
                try rulesStore.moveRule(id: idB, offset: -1)
                rules = try rulesStore.rules()
                try expectEqual(rules[0].id, idB)
                // 开关往返
                try rulesStore.setEnabled(id: idA, enabled: false)
                rules = try rulesStore.rules()
                try expectEqual(rules.first { $0.id == idA }?.enabled, false)
                // 删除
                try rulesStore.deleteRule(ids: [idA, idB])
                try expectEqual(try rulesStore.rules().count, 0)
            },

            TestDesc(suite: "ClassificationRules", name: "migrationV7ToV8PreservesData") {
                let dir = Fixtures.makeTempDir("classify-migrate")
                defer { Fixtures.cleanup(dir) }
                let store = try Fixtures.openStore(in: dir)
                let favorites = FavoritesStore(indexStore: store)
                _ = try favorites.add(.search(query: "旧检索"))
                try store.upsertBook(makeBook("b1", title: "旧书", author: nil))
                let reopened = try Fixtures.openStore(in: dir)
                let tables = try reopened.db.prepare(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('classification_rules','book_classifications') ORDER BY name;")
                var names: [String] = []
                while try tables.step() { names.append(tables.text(0)) }
                try expectEqual(names, ["book_classifications", "classification_rules"])
                let ver = try reopened.db.prepare("SELECT value FROM meta WHERE key='index_schema_version';")
                _ = try ver.step()
                try expectEqual(ver.text(0), String(IndexStore.currentSchemaVersion))
                let favs = try FavoritesStore(indexStore: reopened).all()
                try expectEqual(favs.count, 1)
                try expectEqual(favs[0].target, FavoriteTarget.search(query: "旧检索"))
                let book = try reopened.book(byID: "b1")
                try expectEqual(book?.title, "旧书")
                // CHECK 约束在位：非法算法档拒写（fail-closed）
                let bad = try reopened.db.prepare(
                    "INSERT INTO classification_rules(name, match_text, algorithm, target_category) VALUES('x','y','regex','z');")
                try expectThrows(try bad.run())
            },
        ]
    }
}
