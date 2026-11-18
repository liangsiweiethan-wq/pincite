import SwiftUI
import PDFKit

// MARK: - iOS 库模型（接线）

@MainActor
final class LibraryModel: ObservableObject {
    // MARK: 副本与检索状态

    enum ReplicaState: Equatable {
        case noReplica           // 副本不存在：引导去设置下载，绝不静默空页
        case failed(String)      // 打开失败（schema 门禁/损坏）：如实展示原因
        case ready
    }

    @Published private(set) var replicaState: ReplicaState = .noReplica
    @Published private(set) var books: [IndexStore.BookRow] = []
    @Published var downloadMessage: String = ""
    @Published var isDownloading = false

    private var store: IndexStore?
    private var search: SearchService?
    private(set) var highlights: HighlightStore?
    private(set) var strokes: InkStrokesStore?

    // MARK: 落点常量

    /// 只读副本（IndexReplicaManager.Configuration 生产默认布局）。
    static var replicaURL: URL {
        AppSupportPaths.appDirectory("replica/index.db")
    }
    /// 批注/涂画独立库（iPad 可写；iPhone 装配但不暴露写入口）。
    static var annotationsURL: URL {
        AppSupportPaths.appDirectory("annotations.db")
    }
    /// 原件容器目录（Documents/Library/；Files 导入与 WebDAV 下载共用）。
    static var originalsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Library", isDirectory: true)
    }

    // MARK: 生命周期

    init() {
        openReplica()
        openAnnotations()
    }

    /// 只读打开副本；失败 fail-closed 展示原因（绝不静默空页）。
    func openReplica() {
        let url = Self.replicaURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            replicaState = .noReplica
            store = nil
            search = nil
            books = []
            return
        }
        do {
            let s = try IndexStore(path: url, options: .init(readOnlyReplica: true))
            store = s
            search = SearchService(store: s)
            books = try s.allBooks()
            replicaState = .ready
        } catch {
            store = nil
            search = nil
            books = []
            replicaState = .failed(String(describing: error))
        }
    }

    /// 批注/涂画库（独立 annotations.db；表缺失即空，不猜）。
    private func openAnnotations() {
        let url = Self.annotationsURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let db = try SQLiteDatabase(path: url.path)
            highlights = HighlightStore(db: db)
            strokes = InkStrokesStore(db: db)
        } catch {
            highlights = nil
            strokes = nil
        }
    }

    // MARK: 检索（只读通道）

    func matchingBooks(_ rawQuery: String) throws -> [SearchService.BookHitSummary] {
        guard let search else { return [] }
        return try search.matchingBooks(rawQuery)
    }

    /// 书内页级命中（双开一致性已由 ReadOnlySearchTests 断言固定：与 Mac 全等）。
    func detailedHits(_ rawQuery: String, bookID: String) throws -> [SearchHit] {
        guard let search else { return [] }
        var options = SearchOptions()
        options.filter = SearchFilter()
        options.filter?.bookIDEquals = bookID
        return try search.searchDetailed(rawQuery, options: options).hits
    }

    func book(id: String) -> IndexStore.BookRow? {
        books.first { $0.id == id }
    }

    // MARK: 原件两通道（永不写入原件——只拷贝/下载进容器）

    @discardableResult
    func importOriginal(from url: URL) throws -> String? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: Self.originalsDirectory,
                                                withIntermediateDirectories: true)
        let fingerprint = try Fingerprint.sha256Hex(ofFileAt: url)
        let target = Self.originalsDirectory
            .appendingPathComponent("\(fingerprint.prefix(16))-\(url.lastPathComponent)")
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.copyItem(at: url, to: target)
        }
        let copied = try Fingerprint.sha256Hex(ofFileAt: target)
        guard copied == fingerprint else {
            try? FileManager.default.removeItem(at: target)
            throw LibraryError("拷贝后指纹不符（导入已取消）")
        }
        return books.first { $0.fingerprint == fingerprint }?.title
            ?? books.first { $0.fingerprint == fingerprint }?.fileName
    }

    /// 本地已有原件（按指纹）。
    func localOriginalURL(fingerprint: String) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.originalsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.lastPathComponent.hasPrefix(String(fingerprint.prefix(16))) }
    }

    func downloadOriginal(book: IndexStore.BookRow, libraryRoot: String,
                          serverBase: String, username: String, password: String) async throws {
        guard !libraryRoot.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LibraryError("书库 WebDAV 根路径未配置")
        }
        let client = try WebDAVClient(serverBase: WebDAVClient.validatedBase(serverBase),
                                      username: username, password: password)
        let root = libraryRoot.hasSuffix("/") ? String(libraryRoot.dropLast()) : libraryRoot
        let remotePath = root + "/" + book.relPath
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("original-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await client.download(remotePath: remotePath,
                                  to: temporary,
                                  expectedBytes: book.fileSize,
                                  absoluteCap: WebDAVClient.absoluteDownloadCap)
        // 指纹守卫（fail-closed）：不符删临时件报错。
        let actual = try Fingerprint.sha256Hex(ofFileAt: temporary)
        guard actual == book.fingerprint else {
            throw LibraryError("下载件指纹不符（已删除）：原件可能已更新，请回 Mac 重新上传索引")
        }
        try FileManager.default.createDirectory(at: Self.originalsDirectory,
                                                withIntermediateDirectories: true)
        let target = Self.originalsDirectory
            .appendingPathComponent("\(book.fingerprint.prefix(16))-\(book.fileName)")
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }


    func downloadReplica(serverBase: String, username: String, password: String) async {
        isDownloading = true
        defer { isDownloading = false }
        do {
            let client = try WebDAVClient(serverBase: WebDAVClient.validatedBase(serverBase),
                                          username: username, password: password)
            let loader = WebDAVReplicaLoader(client: client)
            let manager = IndexReplicaManager(
                loader: loader,
                configuration: .init(
                    replicaDirectory: AppSupportPaths.appDirectory("replica"),
                    tmpDirectory: AppSupportPaths.appDirectory("replica-tmp")))
            let outcome = try await manager.syncReplica()
            switch outcome {
            case .replaced(let hash, let volumes):
                downloadMessage = L10n.iosReplicaDownloaded(volumes: volumes, hash: String(hash.prefix(12)))
            case .skippedIdentical:
                downloadMessage = L10n.iosReplicaUpToDate
            }
            openReplica()
            NotificationCenter.default.post(name: .watchCompanionPushRequested, object: nil)
        } catch {
            downloadMessage = L10n.iosReplicaDownloadFailed(String(describing: error))
        }
    }

    // MARK: Share Extension 入站收录（启动/前台拉取合并）

    /// App Group 收件箱 → 书域拉取（fileReception 语义）：PDF 复制入
    /// Documents/Library（原件待索引域，既有管线接管）；URL 文本入
    /// AppSupport/share-captures.json（与出站 share-outbox.json 对称）。
    /// Core ShareReceive.pull 已幂等（同名跳过/成功才消费/怪名不收）；
    /// 无组容器/空收件箱＝零动作。回执文案供界面如实展示，不静默。
    @Published private(set) var shareInboxMessage: String?

    func pullShareInbox() {
        guard let container = ShareReceive.groupContainer() else {
            shareInboxMessage = L10n.iosShareInboxUnavailable
            return
        }
        let outcome = ShareReceive.pull(
            inbox: ShareReceive.inboxDirectory(in: container),
            originalsDirectory: Self.originalsDirectory,
            capturesFile: AppSupportPaths.appDirectory("share-captures.json"))
        let message = L10n.iosShareInboxMerged(pdf: outcome.mergedPDFs.count,
                                               captures: outcome.mergedCaptures.count,
                                               failed: outcome.failed.count)
        shareInboxMessage = message.isEmpty ? nil : message
    }

    // MARK: 批注/涂画导出导入（导出口：整库可重建）

    /// 整库导出（含墓碑）→ 临时 JSON（出站分享）。
    func exportAnnotationBundle() throws -> URL {
        guard let db = annotationsDatabaseURL else { throw LibraryError("批注库未就绪") }
        let bundle = try AnnotationBundle.export(db: db,
                                                 deviceID: DeviceIdentity.deviceID())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotations-\(Int(Date().timeIntervalSince1970)).json")
        try bundle.jsonData().write(to: url, options: .atomic)
        return url
    }

    /// 手动导入（AirDrop/Files 送达的 JSON）→ 合并引擎（fail-closed）。
    func importAnnotationBundle(from url: URL) throws -> AnnotationMergeEngine.Outcome {
        guard let db = annotationsDatabaseURL else { throw LibraryError("批注库未就绪") }
        let data = try Data(contentsOf: url)
        let bundle = try AnnotationBundle.parse(data)
        return try AnnotationMergeEngine(db: db).merge(bundle: bundle)
    }

    private var annotationsDatabaseURL: SQLiteDatabase? {
        try? SQLiteDatabase(path: Self.annotationsURL.path)
    }

    // MARK: 手表伴侣：今日一句（确定性抽取 + 当日缓存）

    func extractDailyQuote() -> WatchDailyQuote? {
        let today = WatchCompanion.dateString()
        let key = WatchCompanion.dailyQuoteCacheKey()
        if let data = UserDefaults.standard.data(forKey: key),
           let cached = try? JSONDecoder().decode(WatchDailyQuote.self, from: data),
           !WatchCompanion.needsRepick(cachedDate: cached.date, today: today) {
            return cached
        }
        return repickDailyQuote(today: today, cacheKey: key)
    }

    private func repickDailyQuote(today: String, cacheKey: String) -> WatchDailyQuote? {
        guard let store else { return nil }
        guard let quotes = try? QuoteExtractor.extract(from: store,
                                                       limit: QuoteExtractor.defaultExtractionLimit,
                                                       date: Date()),
              let first = quotes.first else { return nil }
        let title = books.first { $0.id == first.bookID }?.title ?? first.fileName
        let quote = WatchDailyQuote(sentence: first.sentence, bookTitle: title,
                                    bookFileName: first.fileName,
                                    physicalPage: first.pageNumber, date: today)
        if let data = try? JSONEncoder().encode(quote) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        return quote
    }
}

extension Notification.Name {
    static let watchCompanionPushRequested = Notification.Name("watch.companionPushRequested")
}

struct LibraryError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}
