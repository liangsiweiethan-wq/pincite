import Foundation

// MARK: - Rename rebind

public struct RenameReceipt: Codable, Equatable {
    public let oldPath: String
    public let newPath: String

    public init(oldPath: String, newPath: String) {
        self.oldPath = oldPath
        self.newPath = newPath
    }

    enum CodingKeys: String, CodingKey {
        case oldPath = "old_path"
        case newPath = "new_path"
    }
}

public struct RebindResult: Codable, Equatable {
    public let oldPath: String
    public let newPath: String
    public let status: String
    public let reason: String

    public init(oldPath: String, newPath: String, status: String, reason: String) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.status = status
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case oldPath = "old_path"
        case newPath = "new_path"
        case status
        case reason
    }
}

public struct RebindReport: Codable, Equatable {
    public let results: [RebindResult]
    public let failed: Bool
    public let upReboundCount: Int
    public let alreadyReboundCount: Int
    public let dryRunHitCount: Int
    public let refusedCount: Int

    public init(results: [RebindResult], failed: Bool,
                upReboundCount: Int, alreadyReboundCount: Int,
                dryRunHitCount: Int, refusedCount: Int) {
        self.results = results
        self.failed = failed
        self.upReboundCount = upReboundCount
        self.alreadyReboundCount = alreadyReboundCount
        self.dryRunHitCount = dryRunHitCount
        self.refusedCount = refusedCount
    }

    enum CodingKeys: String, CodingKey {
        case results
        case failed
        case upReboundCount = "up_rebound_count"
        case alreadyReboundCount = "already_rebound_count"
        case dryRunHitCount = "dry_run_hit_count"
        case refusedCount = "refused_count"
    }
}


extension IndexStore {
    public func rebindRenamedBooks(_ receipts: [RenameReceipt], dryRun: Bool = false) throws -> RebindReport {
        lock.lock()
        defer { lock.unlock() }

        var plans: [RebindPlan] = []
        plans.reserveCapacity(receipts.count)
        var results: [RebindResult] = []
        results.reserveCapacity(receipts.count)
        var refused = false
        var targetOwners: [String: String] = [:]

        for receipt in receipts {
            let plan = try validateRebindLocked(receipt, targetOwners: &targetOwners)
            plans.append(plan)
            if let result = plan.result {
                results.append(result)
                refused = true
            } else if dryRun {
                results.append(RebindResult(oldPath: receipt.oldPath, newPath: receipt.newPath,
                                            status: "DRY_RUN_HIT", reason: plan.reason))
            } else if plan.alreadyRebound {
                results.append(RebindResult(oldPath: receipt.oldPath, newPath: receipt.newPath,
                                            status: "ALREADY_REBOUND", reason: plan.reason))
            } else {
                results.append(RebindResult(oldPath: receipt.oldPath, newPath: receipt.newPath,
                                            status: "UP_REBOUND", reason: plan.reason))
            }
        }

        if refused || dryRun {
            // 任一行 REFUSED⇒整批零写入；该批内本可成功的行也如实标 REFUSED
            // （不伪装成命中，也不假装已写）。
            if refused {
                results = results.map { result in
                    result.status == "REFUSED" ? result
                        : RebindResult(oldPath: result.oldPath, newPath: result.newPath,
                                       status: "REFUSED", reason: "同批有行被拒，整批未写入")
                }
            }
            return makeRebindReport(results: results)
        }

        let writes = plans.filter { !$0.alreadyRebound }
        guard !writes.isEmpty else { return makeRebindReport(results: results) }

        try db.exec("BEGIN IMMEDIATE;")
        do {
            for plan in writes {
                if let bookID = plan.bookID, let rootPath = plan.rootPath,
                   let relPath = plan.relPath, let fileName = plan.fileName {
                    let update = try db.prepare("""
                        UPDATE books SET real_path=?, root_path=?, rel_path=?, file_name=? WHERE id=?;
                        """)
                    try update.bindText(1, plan.receipt.newPath)
                    try update.bindText(2, rootPath)
                    try update.bindText(3, relPath)
                    try update.bindText(4, fileName)
                    try update.bindText(5, bookID)
                    try update.run()

                    if plan.fileNameChanged {
                        try deletePinyinRowLocked(bookID: bookID)
                        let source = try db.prepare("SELECT file_name, title, author FROM books WHERE id=?;")
                        try source.bindText(1, bookID)
                        var projectionSource = ""
                        if try source.step() {
                            projectionSource = [source.text(0), source.text(1), source.text(2)]
                                .filter { !$0.isEmpty }.joined(separator: " ")
                        }
                        let insert = try db.prepare("INSERT OR REPLACE INTO book_pinyin(book_id, pinyin_norm) VALUES(?,?);")
                        try insert.bindText(1, bookID)
                        try insert.bindText(2, PinyinNorm.transform(projectionSource))
                        try insert.run()
                    }
                }

                if plan.ocrMatched {
                    let ocr = try db.prepare("UPDATE ocr_books SET ocr_real_path=? WHERE ocr_real_path=?;")
                    try ocr.bindText(1, plan.receipt.newPath)
                    try ocr.bindText(2, plan.receipt.oldPath)
                    try ocr.run()
                }
            }
            try db.exec("COMMIT;")
        } catch {
            db.tryExec("ROLLBACK;")
            throw error
        }
        try purgeQueryCachesLocked()
        return makeRebindReport(results: results)
    }

    private struct RebindPlan {
        let receipt: RenameReceipt
        let bookID: String?
        let rootPath: String?
        let relPath: String?
        let fileName: String?
        let fileNameChanged: Bool
        let ocrMatched: Bool
        let alreadyRebound: Bool
        let reason: String
        let result: RebindResult?
    }

    private func validateRebindLocked(_ receipt: RenameReceipt,
                                      targetOwners: inout [String: String]) throws -> RebindPlan {
        // OCR 侧与 books 侧独立：先按路径查 OCR（命中即该书的 OCR 文件也改了名）。
        let ocrMatched = try rebindOCRExistsLocked(oldPath: receipt.oldPath)
        let old = try rebindBookFieldsLocked(realPath: receipt.oldPath)

        guard let old else {
            // 无 books 行：要么已回绑过（newPath 绑同一书⇒幂等），要么纯 OCR 行
            // （OCR 文件单独改名，books 不参与）。两者都仍须过盘上与冲突校验。
            let newBook = try rebindBookFieldsLocked(realPath: receipt.newPath)
            if let newBook {
                return RebindPlan(receipt: receipt, bookID: newBook.id, rootPath: newBook.rootPath,
                                  relPath: newBook.relPath, fileName: newBook.fileName,
                                  fileNameChanged: false, ocrMatched: false, alreadyRebound: true,
                                  reason: "旧路径已完成回绑", result: nil)
            }
            guard ocrMatched else {
                return refusedPlan(receipt, reason: "旧路径不在索引")
            }
            return try ocrOnlyPlan(receipt, ocrMatched: ocrMatched, targetOwners: &targetOwners)
        }

        let fm = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: receipt.newPath, isDirectory: &isDirectory) else {
            return refusedPlan(receipt, reason: "新路径不存在")
        }
        guard !isDirectory.boolValue else {
            return refusedPlan(receipt, reason: "新路径是目录")
        }
        guard !fm.fileExists(atPath: receipt.oldPath) else {
            return refusedPlan(receipt, reason: "旧盘路径仍在（复制而非改名）")
        }
        if let newBook = try rebindBookFieldsLocked(realPath: receipt.newPath), newBook.id != old.id {
            return refusedPlan(receipt, reason: "新路径已属别的书")
        }
        if let owner = targetOwners[receipt.newPath], owner != old.id {
            return refusedPlan(receipt, reason: "新路径在本次已映射给别的书")
        }
        targetOwners[receipt.newPath] = old.id

        guard let placement = rebindRelativePath(old: old, newPath: receipt.newPath) else {
            return refusedPlan(receipt, reason: "跨根移动，本次不支持")
        }
        let relPath = placement.relPath
        let fileName = URL(fileURLWithPath: receipt.newPath).lastPathComponent
        return RebindPlan(receipt: receipt, bookID: old.id, rootPath: placement.rootPath,
                          relPath: relPath, fileName: fileName,
                          fileNameChanged: fileName != old.fileName, ocrMatched: ocrMatched,
                          alreadyRebound: false, reason: "回绑成功", result: nil)
    }

    /// 相对位置守卫（宽松版）。
    private func rebindRelativePath(old: RebindBookFields,
                                    newPath: String) -> (relPath: String, rootPath: String)? {
        let oldPath = old.realPath

        // 「换目录还认不认」的唯一判据：**旧路径在盘上已消失**。
        //   改名（含把作者文件夹整层改译名）⇒ 旧文件没了 ⇒ 放行；
        //   复制/挪入/搬库 ⇒ 旧文件还在 ⇒ 拒（上一行的旧盘路径守卫也会拦）。
        // 不靠路径长得像来判：同名不同文档挪进来也会「像」，只有盘上事实能分辨。
        // 注意不能拿「旧目录还在吗」当判据——书就放在库里时，旧目录就是库根本身，
        // 永远存在，那样会把所有同库改名都误拒。
        guard !FileManager.default.fileExists(atPath: oldPath) else { return nil }

        let prefix = old.rootPath == "/" ? "/" : (old.rootPath.hasSuffix("/") ? old.rootPath : old.rootPath + "/")
        if newPath.hasPrefix(prefix) {
            return (newPath.dropFirst(prefix.count).description, old.rootPath)
        }
        let parent = (newPath as NSString).deletingLastPathComponent
        return (URL(fileURLWithPath: newPath).lastPathComponent, parent.isEmpty ? "/" : parent)
    }

    /// 纯 OCR 行（books 无该 oldPath）：仍要求新路径真实存在且旧路径已消失，
    /// 并禁止与同批其它行的目标冲突；rootPath 前缀守卫不适用（无书记录）。
    private func ocrOnlyPlan(_ receipt: RenameReceipt, ocrMatched: Bool,
                             targetOwners: inout [String: String]) throws -> RebindPlan {
        let fm = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: receipt.newPath, isDirectory: &isDirectory) else {
            return refusedPlan(receipt, reason: "新路径不存在")
        }
        guard !isDirectory.boolValue else {
            return refusedPlan(receipt, reason: "新路径是目录")
        }
        guard !fm.fileExists(atPath: receipt.oldPath) else {
            return refusedPlan(receipt, reason: "旧盘路径仍在（复制而非改名）")
        }
        if targetOwners[receipt.newPath] != nil {
            return refusedPlan(receipt, reason: "新路径在本次已映射给别的书")
        }
        targetOwners[receipt.newPath] = "ocr:\(receipt.oldPath)"
        return RebindPlan(receipt: receipt, bookID: nil, rootPath: nil, relPath: nil, fileName: nil,
                          fileNameChanged: false, ocrMatched: ocrMatched, alreadyRebound: false,
                          reason: "OCR 配对路径回绑", result: nil)
    }

    private func refusedPlan(_ receipt: RenameReceipt, reason: String) -> RebindPlan {
        RebindPlan(receipt: receipt, bookID: nil, rootPath: nil, relPath: nil, fileName: nil,
                   fileNameChanged: false, ocrMatched: false, alreadyRebound: false,
                   reason: reason,
                   result: RebindResult(oldPath: receipt.oldPath, newPath: receipt.newPath,
                                        status: "REFUSED", reason: reason))
    }

    private struct RebindBookFields {
        let id: String
        let realPath: String
        let rootPath: String
        let relPath: String
        let fileName: String
    }

    private func rebindBookFieldsLocked(realPath: String) throws -> RebindBookFields? {
        let statement = try db.prepare("SELECT id, real_path, root_path, rel_path, file_name FROM books WHERE real_path=?;")
        try statement.bindText(1, realPath)
        guard try statement.step() else { return nil }
        return RebindBookFields(id: statement.text(0), realPath: statement.text(1),
                                rootPath: statement.text(2), relPath: statement.text(3),
                                fileName: statement.text(4))
    }

    private func rebindOCRExistsLocked(oldPath: String) throws -> Bool {
        let statement = try db.prepare("SELECT 1 FROM ocr_books WHERE ocr_real_path=? LIMIT 1;")
        try statement.bindText(1, oldPath)
        return try statement.step()
    }

    private func makeRebindReport(results: [RebindResult]) -> RebindReport {
        RebindReport(results: results, failed: results.contains { $0.status == "REFUSED" },
                     upReboundCount: results.filter { $0.status == "UP_REBOUND" }.count,
                     alreadyReboundCount: results.filter { $0.status == "ALREADY_REBOUND" }.count,
                     dryRunHitCount: results.filter { $0.status == "DRY_RUN_HIT" }.count,
                     refusedCount: results.filter { $0.status == "REFUSED" }.count)
    }
}
