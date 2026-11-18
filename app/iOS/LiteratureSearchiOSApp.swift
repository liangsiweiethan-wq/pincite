import SwiftUI
import UniformTypeIdentifiers
import WatchConnectivity
import Combine
// Core sources are compiled into this target for iOS Xcode builds; the import
// only applies when LiteratureCore comes from the macOS static library.
#if canImport(LiteratureCore)
import LiteratureCore
#endif


@main
struct LiteratureSearchiOSApp: App {
    @StateObject private var model = IOSAppModel()
    @StateObject private var library = LibraryModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environmentObject(model)
                .environmentObject(library)
                .onOpenURL { url in
                    // 检索深链（既有）。
                    if case .search(let q)? = DeepLink.parse(url) {
                        model.pendingDeepLinkQuery = q
                        return
                    }
                    if Self.shareURL(url) != nil {
                        library.enqueueSharedURL(url)
                    }
                }
                .onAppear {
                    // 触发点：冷启动首拉（前台激活另有 scenePhase 钩）。
                    library.pullShareInbox()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    library.pullShareInbox()
                    if WatchCompanion.needsRepick(
                        cachedDate: ReadingProgressRecorder.lastCompanionPushDate,
                        today: WatchCompanion.dateString()) {
                        model.pushWatchCompanion(library: library)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: .watchCompanionPushRequested)) { _ in
                    model.pushWatchCompanion(library: library)
                }
        }
    }

    /// 解析 share 深链的 url 参数（本文件内私有小解析；失败返回 nil 不猜）。
    static func shareURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "literaturesearch",
              url.host?.lowercased() == "share" else { return nil }
        guard let query = url.query else { return nil }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "url",
               let decoded = String(kv[1]).removingPercentEncoding,
               let target = URL(string: decoded), target.scheme != nil {
                return target
            }
        }
        return nil
    }
}

@MainActor
final class IOSAppModel: ObservableObject {
    @Published var history: [HistoryEntry] = []
    @Published var coverageText: String?
    @Published var importedBooks: [SyncBook] = []
    @Published var importMessage: String = ""
    @Published var pendingDeepLinkQuery: String? {
        didSet { if pendingDeepLinkQuery != nil { reload() } }
    }
    @Published var watchMessage: String = ""

    let store: SharedHistoryStore
    private let bridge = PhoneWatchBridge()

    init() {
        store = SharedHistoryStore(fileURL: SharedHistoryStore.sharedFileURL())
        bridge.activate(onStateChange: { [weak self] in self?.watchMessage = $0 })
        // 桥内双槽是进程内存态，跨启动清零——推送前摘要槽为空时
        // 由 provider 现场重建（SharedHistoryStore 常在，空历史也是合法摘要），
        // 伴侣推送必伴摘要，从发送侧根除伴侣单键 context。
        bridge.summaryProvider = { [weak self] in
            guard let self else { return nil }
            return WatchSummaryBuilder.build(coverage: self.store.coverage(),
                                             history: self.store.history())
        }
        reload()
    }

    func reload() {
        history = store.history()
        if let coverage = store.coverage() {
            var line = "书 \(coverage.bookCount) · 页 \(coverage.pageCount)"
            if let noText = coverage.pagesWithoutText { line += " · 无文本页 \(noText)" }
            if let errors = coverage.errorBooks, errors > 0 { line += " · 错误 \(errors)" }
            coverageText = line
        } else {
            coverageText = nil
        }
    }

    /// Import via the Files picker. Security-scoped access is started only
    /// around reading the explicitly chosen file.
    func importSnapshot(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try SyncSnapshotCodec.decode(data)
            for entry in snapshot.history {
                store.record(query: entry.query, hitCount: entry.hitCount, now: entry.at)
            }
            store.update(coverage: CoverageSnapshot(
                bookCount: snapshot.coverage?.bookCount ?? snapshot.books.count,
                pageCount: snapshot.coverage?.pageCount ?? 0,
                lastIndexedAt: snapshot.coverage?.lastIndexedAt.map { Date(timeIntervalSince1970: $0) },
                rootName: nil, // a root name is a filesystem fact on another device
                rootCount: nil,
                pagesWithoutText: snapshot.coverage?.pagesWithoutText,
                errorBooks: snapshot.coverage?.errorBooks))
            importedBooks = snapshot.books
            reload()
            importMessage = "已导入 v\(snapshot.schemaVersion)：书目 \(snapshot.books.count)，历史 \(snapshot.history.count) 条"
            pushWatchSummary()
        } catch {
            importMessage = "导入失败：\(error)"
        }
    }

    /// Watch gets the truncated summary only (never book lists, never text).
    func pushWatchSummary() {
        do {
            let summary = WatchSummaryBuilder.build(coverage: store.coverage(), history: store.history())
            try bridge.send(summary)
            watchMessage = "已向手表发送摘要（\(summary.queries.count) 条查询，截断=\(summary.truncated ? "是" : "否")）"
        } catch {
            watchMessage = "手表摘要未发送：\(error)"
        }
    }

    /// 手表伴侣面（今日一句 + 阅读进度）。经 bridge.sendCompanion
    /// 合并推送——applicationContext 单槽，摘要键自动随行，推伴侣不丢摘要
    /// （合并合同在 Core WatchCompanion.makeContext，测试断言固定）。
    func pushWatchCompanion(library: LibraryModel) {
        do {
            let payload = try WatchCompanion.build(
                pushedAt: Date(),
                dailyQuote: library.extractDailyQuote(),
                progress: ReadingProgressRecorder.companionProgress())
            let data = try WatchCompanionCodec.encode(payload)
            try bridge.sendCompanion(data)
            ReadingProgressRecorder.markCompanionPushed()
            var parts: [String] = []
            if payload.dailyQuote != nil { parts.append("今日一句") }
            if payload.progress != nil { parts.append("阅读进度") }
            watchMessage = L10n.iosWatchCompanionSent(parts.joined(separator: "＋"))
        } catch WatchCompanionError.emptyPayload {
            watchMessage = L10n.iosWatchCompanionNothing
        } catch {
            watchMessage = L10n.iosWatchCompanionFailed(String(describing: error))
        }
    }
}

// MARK: - 根视图（Tab：书库 / 检索 / 设置；既有摘要面并入设置 Tab）

struct IOSRootView: View {
    @EnvironmentObject var model: IOSAppModel
    @EnvironmentObject var library: LibraryModel

    var body: some View {
        TabView {
            NavigationStack {
                LibraryBrowseView()
                    .navigationDestination(for: BookNavTarget.self) { target in
                        if let book = library.books.first(where: { $0.id == target.id }) {
                            OriginalEntryView(book: book)
                        } else {
                            ContentUnavailableCompat(title: L10n.iosReplicaFailedTitle,
                                                     detail: L10n.iosBookMissing)
                        }
                    }
            }
            .tabItem { Label(L10n.iosTabLibrary, systemImage: "books.vertical") }

            NavigationStack {
                SearchPaneView()
            }
            .tabItem { Label(L10n.search, systemImage: "magnifyingglass") }

            NavigationStack {
                IOSSettingsView()
            }
            .tabItem { Label(L10n.iosTabSettings, systemImage: "gearshape") }
        }
    }
}

// MARK: - 设置面（副本下载 / 批注导入 / 既有摘要面 / 手表）

struct IOSSettingsView: View {
    @EnvironmentObject var model: IOSAppModel
    @EnvironmentObject var library: LibraryModel
    @AppStorage("ios.webdav.serverBase") private var serverBase = ""
    @AppStorage("ios.webdav.username") private var username = ""
    @AppStorage("ios.webdav.libraryRoot") private var libraryRoot = ""
    @State private var password = ""
    @State private var showImporter = false
    @State private var showSnapshotImporter = false
    @State private var message = ""

    var body: some View {
        List {
            Section(L10n.iosReplicaSection) {
                TextField("https://dav.example.com/webdav", text: $serverBase)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField(L10n.iosWebDAVUsername, text: $username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField(L10n.iosWebDAVPassword, text: $password)
                Button {
                    savePassword()
                    Task { await library.downloadReplica(serverBase: serverBase,
                                                         username: username,
                                                         password: currentPassword()) }
                } label: {
                    if library.isDownloading {
                        HStack { ProgressView(); Text(L10n.iosReplicaDownloading) }
                    } else {
                        Text(L10n.iosReplicaDownloadNow)
                    }
                }
                .disabled(library.isDownloading || serverBase.isEmpty || username.isEmpty)
                if !library.downloadMessage.isEmpty {
                    Text(library.downloadMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.iosReplicaPrivacyNote).font(.caption2).foregroundStyle(.secondary)
            }

            Section(L10n.iosAnnotationsSection) {
                Button(L10n.iosAnnotationsImport) { showImporter = true }
                Button(L10n.iosAnnotationsExport) { exportBundle() }
                if !WritingCapability.isWritable {
                    Text(L10n.iosReadOnlyDeviceNotice).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section(L10n.iosLibraryRootSection) {
                TextField(L10n.iosLibraryRootPlaceholder, text: $libraryRoot)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Text(L10n.iosLibraryRootNote).font(.caption2).foregroundStyle(.secondary)
            }

            Section("快照（来自 macOS 导出；白名单字段）") {
                Button("导入快照 JSON…") { showSnapshotImporter = true }
                if !model.importMessage.isEmpty {
                    Text(model.importMessage).font(.caption).foregroundStyle(.secondary)
                }
                if let line = model.coverageText {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("手表") {
                Button("重新发送摘要") { model.pushWatchSummary() }
                Button(L10n.iosWatchPushCompanion) { model.pushWatchCompanion(library: library) }
                if !model.watchMessage.isEmpty {
                    Text(model.watchMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("关于") {
                Text("手机端不自建索引：检索走 Mac 上传的只读副本；原件 PDF 只读不写入。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.iosTabSettings)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { importAnnotations(url) }
        }
        .fileImporter(isPresented: $showSnapshotImporter, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { model.importSnapshot(from: url) }
        }
    }

    private func currentPassword() -> String {
        if !password.isEmpty { return password }
        let storage = SecurityFrameworkKeyStorage(service: SecurityFrameworkKeyStorage.webdavService)
        return (try? storage.readKey(account: username)) ?? ""
    }

    /// 密码只进本机 Keychain（AfterFirstUnlockThisDeviceOnly，不 iCloud 同步
    private func savePassword() {
        guard !username.isEmpty, !password.isEmpty else { return }
        let storage = SecurityFrameworkKeyStorage(service: SecurityFrameworkKeyStorage.webdavService)
        _ = try? storage.save(password, account: username)
        password = ""
        message = L10n.iosPasswordSaved
    }

    private func importAnnotations(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let outcome = try library.importAnnotationBundle(from: url)
            message = L10n.iosAnnotationsImported(outcome.highlightsInserted + outcome.strokesInserted,
                                                  outcome.duplicatesSkipped)
        } catch {
            message = L10n.iosAnnotationFailed(String(describing: error))
        }
    }

    private func exportBundle() {
        do {
            let url = try library.exportAnnotationBundle()
            message = L10n.iosAnnotationsExported(url.lastPathComponent)
        } catch {
            message = L10n.iosAnnotationFailed(String(describing: error))
        }
    }
}

extension LibraryModel {
    /// share 深链的 URL 入队 + 尝试发送（WebDAV 在位时）。
    func enqueueSharedURL(_ url: URL) {
        let capture = ShareCapture(text: url.absoluteString, sourceLines: ["source: share link"])
        try? ShareCapture.enqueue(capture)
        let cfg = WebDAVSettingsStore().load()
        let storage = SecurityFrameworkKeyStorage(service: SecurityFrameworkKeyStorage.webdavService)
        guard let config = cfg, !config.username.isEmpty else { return }
        let username = config.username
        let password = (try? storage.readKey(account: username)) ?? ""
        guard !password.isEmpty else { return }
        Task {
            if let client = try? WebDAVClient(serverBase: WebDAVClient.validatedBase(config.serverBase),
                                              username: username, password: password) {
                _ = try? await ShareCapture.flush(client: client)
            }
        }
    }
}
