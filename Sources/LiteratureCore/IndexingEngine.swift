import Foundation

// MARK: - Indexing engine

public struct IndexProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable, CustomStringConvertible {
        case scanning, indexing, cleaningUp, done, cancelled
        public var description: String {
            switch self {
            case .scanning: return "scanning"
            case .indexing: return "indexing"
            case .cleaningUp: return "cleaningUp"
            case .done: return "done"
            case .cancelled: return "cancelled"
            }
        }
    }
    public var phase: Phase
    public var filesTotal: Int
    public var filesDone: Int
    public var currentFile: String?
}

public struct IndexRunSummary: Equatable, Sendable {
    public var filesScanned: Int = 0
    public var indexedNew: Int = 0
    public var updated: Int = 0
    public var skippedUnchanged: Int = 0
    public var removed: Int = 0
    public var excluded: Int = 0
    public var unsupported: Int = 0
    public var failed: Int = 0
    public var failures: [String] = []
    public var exclusions: [String] = []
    public var wasCancelled: Bool = false

    public init() {}

    public var filesDone: Int { indexedNew + updated + skippedUnchanged }
}

public final class IndexingEngine {
    private let store: IndexStore
    private let policy: ExclusionPolicy
    private let limits: PDFExtractionLimits
    private let progressHandler: (@Sendable (IndexProgress) -> Void)?
    /// 更新 抽取文本侧车缓存（nil＝不缓存，
    /// 与旧行为等价）。生产接线由 App 侧以 AppSupportPaths.textCacheDirectory
    /// 注入；各 extract 调用点已先算 sha256 指纹，直接传 precomputedSHA256
    /// 零额外哈希成本。
    private let textCache: ExtractionTextCache?
    public init(store: IndexStore, policy: ExclusionPolicy,
                limits: PDFExtractionLimits = PDFExtractionLimits(),
                 progress: (@Sendable (IndexProgress) -> Void)? = nil,
                 textCache: ExtractionTextCache? = nil) {
        self.store = store
        self.policy = policy
        self.limits = limits
        self.progressHandler = progress
        self.textCache = textCache
    }

    private func extract(_ url: URL, fingerprint: String,
                         onPageExtracted: ((Int, Int) -> Void)? = nil) throws -> PDFExtractionResult {
        try PDFTextExtractor.extract(url: url, limits: limits, cache: textCache,
                                     precomputedSHA256: fingerprint,
                                     onPageExtracted: onPageExtracted)
    }

    /// Runs a full incremental pass over `rootURL`. Safe to run in a Task;
    /// honours cooperative cancellation between files.
    public func run(rootURL: URL) async throws -> IndexRunSummary {
        var summary = IndexRunSummary()
        let rootRealPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path

        // 1. Collect candidate files under the explicitly selected root.
        report(IndexProgress(phase: .scanning, filesTotal: 0, filesDone: 0, currentFile: nil))
        let fm = FileManager.default
        let rootAttributes = try fm.attributesOfItem(atPath: rootRealPath)
        guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileReadInvalidFileName, userInfo: [NSURLErrorKey: rootURL])
        }
        var scanError: Error?
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, error in
                scanError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: rootURL])
        }
        var candidates: [URL] = []
        var excludedCandidates: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: item.path, isDirectory: &isDir)
            if isDir.boolValue { continue }
            // The tool's own storage (index.db + WAL/SHM) is never library
            // content; counting it as "unsupported" would poison coverage.
            if Self.isOwnStorageFile(item) { continue }
            let verdict = policy.evaluate(candidateFileURL: item, rootURL: rootURL)
            switch verdict {
            case .allowed:
                candidates.append(item)
            case .unsupportedFileType:
                summary.unsupported += 1 // counted so coverage shows the whole picture
            default:
                summary.excluded += 1
                summary.exclusions.append("\(item.lastPathComponent) [\(verdictReason(verdict))]")
                if verdict != .symlinkEscape { excludedCandidates.append(item) }
            }
        }
        if let scanError { throw scanError }

        if !excludedCandidates.isEmpty {
            let allowedRealPaths = Set(candidates.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
            for item in excludedCandidates {
                let realPath = item.resolvingSymlinksInPath().standardizedFileURL.path
                if !allowedRealPaths.contains(realPath), let existing = try store.book(byRealPath: realPath) {
                    try store.deleteBook(id: existing.id)
                    try store.dequeueBook(existing.id)
                }
            }
        }

        summary.filesScanned = candidates.count
        report(IndexProgress(phase: .indexing, filesTotal: candidates.count, filesDone: 0, currentFile: nil))

        var seenRealPaths = Set<String>()
        for (i, fileURL) in candidates.enumerated() {
            if Task.isCancelled { summary.wasCancelled = true; break }
            report(IndexProgress(phase: .indexing, filesTotal: candidates.count, filesDone: i, currentFile: fileURL.lastPathComponent))

            let realPath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            seenRealPaths.insert(realPath)

            if let existing = try store.book(byRealPath: realPath),
               policy.evaluateBookID(existing.id) != .allowed {
                try store.deleteBook(id: existing.id)
                try store.dequeueBook(existing.id)
                summary.excluded += 1
                continue
            }

            do {
                let fingerprint = try Fingerprint.sha256Hex(ofFileAt: fileURL)
                let attrs = try fm.attributesOfItem(atPath: fileURL.path)
                let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

                if let existing = try store.book(byRealPath: realPath) {
                    // 只有已成功索引的文件才能跳过；错误记录必须重新验证。
                    if try isCurrent(existing, fingerprint: fingerprint) {
                        summary.skippedUnchanged += 1
                        continue
                    }
                    let extraction = try extract(fileURL, fingerprint: fingerprint)
                    try persist(bookID: existing.id, fileURL: fileURL, rootRealPath: rootRealPath,
                                fingerprint: fingerprint, fileSize: fileSize, mtime: mtime,
                                extraction: extraction, firstFingerprint: existing.firstFingerprint)
                    summary.updated += 1
                } else {
                    let bookID = try newBookID(realPath: realPath, fingerprint: fingerprint)
                    if !isAllowedNewBook(id: bookID, fingerprint: fingerprint) {
                        summary.excluded += 1
                        summary.exclusions.append("\(fileURL.lastPathComponent) [excluded-by-id]")
                        continue
                    }
                    let extraction = try extract(fileURL, fingerprint: fingerprint)
                    try persist(bookID: bookID, fileURL: fileURL, rootRealPath: rootRealPath,
                                fingerprint: fingerprint, fileSize: fileSize, mtime: mtime,
                                extraction: extraction, firstFingerprint: fingerprint)
                    summary.indexedNew += 1
                }
            } catch is CancellationError {
                summary.wasCancelled = true
                break // cancelled mid-run: not a file failure
            } catch {
                summary.failed += 1
                summary.failures.append("\(fileURL.lastPathComponent): \(error)")
                // Record the failure so results never pretend the file is indexed.
                // New files get an explicit error row too (visible in coverage).
                if let existing = try? store.book(byRealPath: realPath) {
                    var bad = existing
                    bad.status = "error"
                    bad.error = String(describing: error)
                    try? store.upsertBook(bad)
                } else if let partialFingerprint = try? Fingerprint.sha256Hex(ofFileAt: fileURL),
                          let errorID = try? newBookID(realPath: realPath, fingerprint: partialFingerprint) {
                    try? store.saveIndexedBook(IndexStore.BookRow(
                        id: errorID, realPath: realPath, rootPath: rootRealPath,
                        relPath: fileURL.lastPathComponent, fileName: fileURL.lastPathComponent,
                        title: nil, author: nil, version: nil, language: nil, metaSource: nil,
                        firstFingerprint: partialFingerprint, fingerprint: partialFingerprint,
                        fileSize: 0, mtime: 0, pageCount: 0, status: "error",
                        error: String(describing: error), indexedAt: Date().timeIntervalSince1970),
                        pages: [])
                }
            }
        }

        // 2. Remove books under this root whose files disappeared.
        if !Task.isCancelled {
            report(IndexProgress(phase: .cleaningUp, filesTotal: candidates.count,
                                 filesDone: summary.filesDone, currentFile: nil))
            let all = try store.allBooks()
            for book in all where book.rootPath == rootRealPath && !seenRealPaths.contains(book.realPath) {
                do {
                    // Skipped package directories can contain books indexed by an older scan.
                    _ = try fm.attributesOfItem(atPath: book.realPath)
                    continue
                } catch let error as CocoaError where error.code == .fileNoSuchFile
                    || error.code == .fileReadNoSuchFile {
                    try store.deleteBook(id: book.id)
                    try store.dequeueBook(book.id)
                }
                summary.removed += 1
            }
        }

        summary.wasCancelled = summary.wasCancelled || Task.isCancelled
        report(IndexProgress(phase: summary.wasCancelled ? .cancelled : .done,
                             filesTotal: candidates.count, filesDone: summary.filesDone, currentFile: nil))

        // Persist the run summary (meta) so the app/UI can show coverage without rerunning.
        if let data = try? JSONEncoder().encode(RunRecord(from: summary, at: Date())),
           let json = String(data: data, encoding: .utf8) {
            try? store.setMetaValue("last_run_summary", json)
        }
        return summary
    }

    /// Explicit-file indexing: read-only, only the named files, no scan, no
    /// deletion of anything else. Every file is policy-checked BEFORE any
    /// content is read.
    public func indexExplicitFiles(urls: [URL]) async throws -> IndexRunSummary {
        var summary = IndexRunSummary()
        summary.filesScanned = urls.count
        report(IndexProgress(phase: .indexing, filesTotal: urls.count, filesDone: 0, currentFile: nil))
        let fm = FileManager.default
        for (i, fileURL) in urls.enumerated() {
            if Task.isCancelled { summary.wasCancelled = true; break }
            report(IndexProgress(phase: .indexing, filesTotal: urls.count, filesDone: i, currentFile: fileURL.lastPathComponent))

            // Policy gate BEFORE reading content (path/ID level only).
            let parent = fileURL.deletingLastPathComponent()
            let verdict = policy.evaluate(candidateFileURL: fileURL, rootURL: parent)
            guard verdict == .allowed else {
                summary.excluded += 1
                summary.exclusions.append("\(fileURL.lastPathComponent) [\(verdictReason(verdict))]")
                continue
            }

            let realPath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            do {
                let existing = try store.book(byRealPath: realPath)
                if let existing, policy.evaluateBookID(existing.id) != .allowed {
                    summary.excluded += 1
                    summary.exclusions.append("\(fileURL.lastPathComponent) [excluded-by-id]")
                    continue
                }
                let fingerprint = try Fingerprint.sha256Hex(ofFileAt: fileURL)
                let attrs = try fm.attributesOfItem(atPath: fileURL.path)
                let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                if let existing {
                    if try isCurrent(existing, fingerprint: fingerprint) {
                        summary.skippedUnchanged += 1
                        continue
                    }
                    let extraction = try extract(fileURL, fingerprint: fingerprint)
                    try persist(bookID: existing.id, fileURL: fileURL, rootRealPath: parent.resolvingSymlinksInPath().standardizedFileURL.path,
                                fingerprint: fingerprint, fileSize: fileSize, mtime: mtime,
                                extraction: extraction, firstFingerprint: existing.firstFingerprint)
                    summary.updated += 1
                } else {
                    let bookID = try newBookID(realPath: realPath, fingerprint: fingerprint)
                    if !isAllowedNewBook(id: bookID, fingerprint: fingerprint) {
                        summary.excluded += 1
                        summary.exclusions.append("\(fileURL.lastPathComponent) [excluded-by-id]")
                        continue
                    }
                    let extraction = try extract(fileURL, fingerprint: fingerprint)
                    try persist(bookID: bookID, fileURL: fileURL, rootRealPath: parent.resolvingSymlinksInPath().standardizedFileURL.path,
                                fingerprint: fingerprint, fileSize: fileSize, mtime: mtime,
                                extraction: extraction, firstFingerprint: fingerprint)
                    summary.indexedNew += 1
                }
            } catch is CancellationError {
                summary.wasCancelled = true
                break
            } catch {
                summary.failed += 1
                summary.failures.append("\(fileURL.lastPathComponent): \(error)")
            }
        }
        summary.wasCancelled = summary.wasCancelled || Task.isCancelled
        report(IndexProgress(phase: summary.wasCancelled ? .cancelled : .done,
                             filesTotal: urls.count, filesDone: summary.filesDone, currentFile: nil))
        return summary
    }

    // MARK: sha256 脏检查单册重索引（Calibre format_hash 为镜）

    public enum ReindexVerdict: String, Equatable, Sendable {
        case unchanged   // sha256 与库内指纹一致（且未 force）：页行不动
        case updated     // 指纹变化或 force：重抽取并替换页行（只动这一本）
        case missing     // book_id 不存在或文件缺失
        case error       // 抽取/落库失败（books 行照 run 基准记 error）
    }

    public struct ReindexBookResult: Equatable, Sendable {
        public let bookID: String
        public let verdict: ReindexVerdict
        public let pages: Int
        public let seconds: Double
        public let message: String?
    }

    /// 单册重索引：定位 book → 重算 Fingerprint.sha256Hex（与全库扫描
    public func reindexBook(bookID: String, force: Bool = false,
                            onPage: (@Sendable (Int, Int) -> Void)? = nil) async throws -> ReindexBookResult {
        let start = Date()
        func result(_ verdict: ReindexVerdict, pages: Int, message: String? = nil) -> ReindexBookResult {
            .init(bookID: bookID, verdict: verdict, pages: pages,
                  seconds: Date().timeIntervalSince(start), message: message)
        }
        guard let book = try store.book(byID: bookID) else {
            return result(.missing, pages: 0, message: "库中无此 book_id")
        }
        let url = URL(fileURLWithPath: book.realPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return result(.missing, pages: book.pageCount, message: "文件缺失: \(book.realPath)")
        }
        // 排除策略先于读内容（路径/ID 级；与既有入口同纪律）。
        guard policy.evaluateBookID(book.id) == .allowed else {
            return result(.error, pages: book.pageCount, message: "book_id 命中排除策略，未读内容")
        }
        do {
            let fingerprint = try Fingerprint.sha256Hex(ofFileAt: url)
            if !force, try isCurrent(book, fingerprint: fingerprint) {
                return result(.unchanged, pages: book.pageCount,
                              message: "sha256 与库内指纹一致，页行未动")
            }
            let extraction = try extract(url, fingerprint: fingerprint,
                                         onPageExtracted: onPage)
            let fm = FileManager.default
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            try persist(bookID: book.id, fileURL: url, rootRealPath: book.rootPath,
                        fingerprint: fingerprint, fileSize: fileSize, mtime: mtime,
                        extraction: extraction, firstFingerprint: book.firstFingerprint)
            return result(.updated, pages: extraction.pageCount)
        } catch {
            // 失败照 run 基准如实记 error 行（结果永不假装已索引）。
            var bad = book
            bad.status = "error"
            bad.error = String(describing: error)
            try? store.upsertBook(bad)
            return result(.error, pages: book.pageCount, message: String(describing: error))
        }
    }

    // MARK: 队列消费（时间预算切片；只读句柄空队列返回）

    public struct QueueConsumeSummary: Equatable, Sendable {
        public var considered: Int = 0      // 到期行数（进入本片时）
        public var indexed: Int = 0
        public var unavailable: Int = 0
        public var missing: Int = 0         // 书行不存在：残留队列行清理
        public var exhaustedBudget: Bool = false
        public var elapsedSeconds: Double = 0.0
    }

    /// 消费到期队列（state != 'indexed' OR queued_version < currentPipelineVersion），
    /// 按 book 逐册切片：每册消费前检查时间预算，到点即存点退出（已完成
    public func runQueued(timeBudget: TimeInterval) async throws -> QueueConsumeSummary {
        var summary = QueueConsumeSummary()
        guard !store.isReadOnlyReplica else { return summary }
        let start = Date()
        let due = try store.dueQueueRows()
        summary.considered = due.count
        let fm = FileManager.default
        // 先消费后查时（配套）：每片至少处理完一册再判预算——
        // 时间预算为**软上限**（每片至少一册，预算极小时仍有确定进展不
        // 空转饿死）；取消协作：外部 Task 取消即存点退出（中断处续跑）。
        var served = 0
        for row in due {
            if served >= 1, Date().timeIntervalSince(start) > timeBudget {
                summary.exhaustedBudget = true
                break
            }
            if Task.isCancelled { break }
            served += 1
            guard let book = try store.book(byID: row.bookID) else {
                try? store.dequeueBook(row.bookID)   // 残留行自愈清理
                summary.missing += 1
                continue
            }
            let url = URL(fileURLWithPath: book.realPath)
            guard FileManager.default.fileExists(atPath: url.path),
                  policy.evaluateBookID(book.id) == .allowed else {
                try? store.setQueueState(bookID: book.id, state: .unavailable,
                                         error: "文件缺失或命中排除策略")
                summary.unavailable += 1
                continue
            }
            do {
                let fingerprint = try Fingerprint.sha256Hex(ofFileAt: url)
                if row.queuedVersion >= IndexStore.currentPipelineVersion,
                   try isCurrent(book, fingerprint: fingerprint) {
                    if (try? store.bookHasTextLayer(bookID: book.id)) ?? false {
                        try store.setQueueState(bookID: book.id, state: .indexed,
                                                queuedVersion: IndexStore.currentPipelineVersion)
                        summary.indexed += 1
                    } else {
                        try store.setQueueState(bookID: book.id, state: .unavailable,
                                                error: "全书无文本层（未OCR，不可索引）")
                        summary.unavailable += 1
                    }
                } else {
                    var pagesDone = 0
                    var charsDone = 0
                    var lastFlush = Date()
                    let extraction = try extract(
                        url, fingerprint: fingerprint,
                        onPageExtracted: { page, pageChars in
                            pagesDone = page
                            charsDone += pageChars
                            let now = Date()
                            if page % 32 == 0 || now.timeIntervalSince(lastFlush) >= 2.0 {
                                lastFlush = now
                                try? self.store.updateQueueProgress(bookID: book.id, pagesTotal: nil,
                                                                    pagesDone: pagesDone, charsDone: charsDone)
                            }
                        })
                    let attrs = try fm.attributesOfItem(atPath: url.path)
                    let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    try persist(bookID: book.id, fileURL: url, rootRealPath: book.rootPath,
                                fingerprint: fingerprint, fileSize: fileSize, mtime: mtime,
                                extraction: extraction, firstFingerprint: book.firstFingerprint)
                    // 完成点写进度终值（pages_total/pages_done/chars_done）。
                    try? store.updateQueueProgress(bookID: book.id, pagesTotal: extraction.pageCount,
                                                   pagesDone: extraction.pageCount, charsDone: charsDone)
                    let hasText = extraction.pages.contains {
                        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    if hasText {
                        try store.setQueueState(bookID: book.id, state: .indexed,
                                                queuedVersion: IndexStore.currentPipelineVersion)
                        summary.indexed += 1
                        // 强制重抽已落实（页行已按新来源落库）。
                    } else {
                        try store.setQueueState(bookID: book.id, state: .unavailable,
                                                error: "全书无文本层（未OCR，不可索引）")
                        summary.unavailable += 1
                    }
                }
            } catch {
                try? store.setQueueState(bookID: book.id, state: .unavailable,
                                         error: String(describing: error))
                summary.unavailable += 1
            }
        }
        summary.elapsedSeconds = Date().timeIntervalSince(start)
        return summary
    }

    // MARK:pending 排空（文件事件驱动增量索引的消费端）

    public struct PendingDrainSummary: Equatable, Sendable {
        public var considered: Int = 0
        public var indexed: Int = 0        // 排空成功（新索引/更新/未变结算）
        public var failed: Int = 0         // 失败（attempts+1 保留）
        public var abandoned: Int = 0      // ≥3 弃试删行
        public var wasCancelled: Bool = false
    }

    /// 排空 index_pending（消费端；watcher settle / App 钩子 / CLI 显式
    /// 触发——Core 不自建定时器）。逐文件走 indexExplicitFiles（既有
    /// 只读显式索引语义，persist 内自动 enqueueBook；逐文件单次调用使成败
    /// 归属精确到行）→ 成功（新索引/更新/未变结算）删 pending 行 → 失败
    /// attempts+1 保留（≥3 弃试删行，防坏件永久占队）。取消协作：取消即停
    /// （未消费行保留，下次排空续）。
    public func drainPending(limit: Int = 64) async throws -> PendingDrainSummary {
        var summary = PendingDrainSummary()
        guard !store.isReadOnlyReplica else { return summary }
        let batch = try store.duePendingPaths(limit: limit)
        summary.considered = batch.count
        for row in batch {
            if Task.isCancelled { summary.wasCancelled = true; break }
            let outcome = try await indexExplicitFiles(urls: [URL(fileURLWithPath: row.path)])
            let ok = outcome.indexedNew + outcome.updated + outcome.skippedUnchanged > 0
            if ok {
                try? store.removePendingPaths([row.path])
                summary.indexed += 1
            } else {
                // 在写保护：mtime 距今 <10s 的
                // 失败件很可能是 watcher settle 后仍在落盘的大 PDF——不计
                // attempts（防半成品写完前被三振弃试），行保留下排空。
                let mtimeAge = (try? URL(fileURLWithPath: row.path).resourceValues(
                    forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate.map { Date().timeIntervalSince($0) } ?? .infinity
                if mtimeAge < 10 {
                    continue
                }
                summary.failed += 1
                if (try? store.bumpPendingAttempts(path: row.path)) == true {
                    summary.abandoned += 1
                }
            }
        }
        summary.wasCancelled = summary.wasCancelled || Task.isCancelled
        return summary
    }

    public struct RunRecord: Codable, Equatable {
        public var filesScanned: Int
        public var indexedNew: Int
        public var updated: Int
        public var skippedUnchanged: Int
        public var removed: Int
        public var excluded: Int
        public var unsupported: Int
        public var failed: Int
        public var cancelled: Bool
        public var at: Date

        init(from s: IndexRunSummary, at date: Date) {
            filesScanned = s.filesScanned; indexedNew = s.indexedNew; updated = s.updated
            skippedUnchanged = s.skippedUnchanged; removed = s.removed; excluded = s.excluded
            unsupported = s.unsupported; failed = s.failed; cancelled = s.wasCancelled; at = date
        }
    }

    // MARK: Internals

    private func newBookID(realPath: String, fingerprint: String) throws -> String {
        let contentID = "b" + String(fingerprint.prefix(20))
        if try store.book(byID: contentID) == nil { return contentID }
        let identity = Data((fingerprint + "\n" + realPath).utf8)
        return "b" + Fingerprint.sha256Hex(of: identity).prefix(20)
    }

    private func isAllowedNewBook(id: String, fingerprint: String) -> Bool {
        // Excluding the content ID also excludes additional copies of that PDF.
        let legacyID = "b" + String(fingerprint.prefix(20))
        return policy.evaluateBookID(id) == .allowed && policy.evaluateBookID(legacyID) == .allowed
    }

    private func isCurrent(_ book: IndexStore.BookRow, fingerprint: String) throws -> Bool {
        guard book.fingerprint == fingerprint, book.status == "ok", book.pageCount > 0 else {
            return false
        }
        return try store.pageCount(bookID: book.id) == book.pageCount
    }

    private func persist(bookID: String, fileURL: URL, rootRealPath: String,
                         fingerprint: String, fileSize: Int64, mtime: Double,
                         extraction: PDFExtractionResult, firstFingerprint: String) throws {
        let rootPath = rootRealPath
        let relPath = fileURL.path.hasPrefix(rootPath + "/")
            ? String(fileURL.path.dropFirst(rootPath.count + 1))
            : fileURL.lastPathComponent

        let book = IndexStore.BookRow(
            id: bookID,
            realPath: fileURL.resolvingSymlinksInPath().standardizedFileURL.path,
            rootPath: rootPath,
            relPath: relPath,
            fileName: fileURL.lastPathComponent,
            title: nil,      // unknown — metadata is never guessed from the file name
            author: nil,     // unknown
            version: nil,    // unknown
            firstFingerprint: firstFingerprint,
            fingerprint: fingerprint,
            fileSize: fileSize,
            mtime: mtime,
            pageCount: extraction.pageCount,
            status: "ok",
            error: nil,
            indexedAt: Date().timeIntervalSince1970
        )
        let pageRows: [IndexStore.PageRow] = extraction.pages.map { p in
            IndexStore.PageRow(
                bookID: bookID,
                pageNumber: p.physicalPage,
                label: p.label,
                printedPage: p.printedPage,
                textOriginal: p.text,
                textNorm: p.normalized.text,
                normStarts: p.normalized.starts,
                normEnds: p.normalized.ends
            )
        }
        try store.saveIndexedBook(book, pages: pageRows)
        try? store.enqueueBook(bookID)
    }

    /// Own storage files (never treated as library content).
    /// /fulltext.db 三件套与抽取缓存件名一并纳入
    /// （分离后全文库为自有存储；watcher/扫描双消费面同源过滤）。
    static func isOwnStorageFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == "index.db" || name == "index.db-wal" || name == "index.db-shm"
            || name == "fulltext.db" || name == "fulltext.db-wal" || name == "fulltext.db-shm"
            || name == "fulltext.db-journal"
            || ExtractionTextCache.isOwnCacheFile(name)
    }

    private func report(_ progress: IndexProgress) {
        progressHandler?(progress)
    }

    private func verdictReason(_ verdict: ExclusionVerdict) -> String {
        switch verdict {
        case .excludedByPathSubstring: return "path-substring"
        case .excludedByGlob: return "glob"
        case .excludedByID: return "book-id/identifier"
        case .symlinkEscape: return "symlink-escape"
        case .unsupportedFileType: return "not-pdf"
        case .allowed: return "allowed"
        }
    }
}
