import SwiftUI
import PDFKit

// MARK: - 书目浏览（books 行只读展示——书名/作者/页数/覆盖，
// 字段基准与桌面 allBooks 列清单同源 IndexStore.swift:815）

/// 导航值包装（IndexStore.BookRow 未声明 Hashable，为免改动 IndexStore，
/// 导航用 id 包装，视图侧再按 id 取回）。
struct BookNavTarget: Hashable {
    let id: String
}

struct LibraryBrowseView: View {
    @EnvironmentObject var model: LibraryModel

    var body: some View {
        Group {
            switch model.replicaState {
            case .noReplica:
                ContentUnavailableCompat(
                    title: L10n.iosReplicaMissingTitle,
                    detail: L10n.iosReplicaMissingDetail)
            case .failed(let reason):
                ContentUnavailableCompat(
                    title: L10n.iosReplicaFailedTitle,
                    detail: reason)
            case .ready:
                List(model.books, id: \.id) { book in
                    NavigationLink(value: BookNavTarget(id: book.id)) {
                        BookRowView(book: book,
                                    hasOriginal: model.localOriginalURL(fingerprint: book.fingerprint) != nil)
                    }
                }
            }
        }
    }
}

/// 书目行（只读展示；页数/文字层覆盖与桌面基准一致）。
struct BookRowView: View {
    let book: IndexStore.BookRow
    var hasOriginal: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(book.title ?? book.fileName)
                .font(.body)
            HStack(spacing: 8) {
                if let author = book.author, !author.isEmpty {
                    Text(author).font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.iosBookPages(book.pageCount))
                    .font(.caption).foregroundStyle(.secondary)
                if hasOriginal {
                    Text(L10n.iosBookOriginalReady)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
        }
    }
}

/// ContentUnavailableView 的 iOS 16 兼容形态（部署目标 17.0，可直接用
/// 系统组件——保底用自绘，避免 API 漂移）。
struct ContentUnavailableCompat: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 阅读器入口：本地原件在 → ReaderView；不在 → 引导两通道

struct OriginalEntryView: View {
    @EnvironmentObject var model: LibraryModel
    let book: IndexStore.BookRow
    @State private var showImporter = false
    @State private var importMessage = ""
    @State private var downloading = false

    var body: some View {
        Group {
            if let local = model.localOriginalURL(fingerprint: book.fingerprint) {
                ReaderContainerView(book: book, pdfURL: local)
            } else {
                VStack(spacing: 16) {
                    Text(L10n.iosOriginalMissing(book.title ?? book.fileName))
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button(L10n.iosOriginalImportFromFiles) { showImporter = true }
                        .buttonStyle(.borderedProminent)
                    Button {
                        downloading = true
                        Task { await downloadOriginal() }
                    } label: {
                        if downloading {
                            ProgressView()
                        } else {
                            Text(L10n.iosOriginalDownloadFromWebDAV)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(downloading)
                    if !importMessage.isEmpty {
                        Text(importMessage)
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    Text(L10n.iosOriginalPrivacyNote)
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf]) { result in
                    if case .success(let url) = result { doImport(url) }
                }
            }
        }
        .navigationTitle(book.title ?? book.fileName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func doImport(_ url: URL) {
        do {
            let matched = try model.importOriginal(from: url)
            importMessage = matched == nil
                ? L10n.iosOriginalImportUnmatched
                : L10n.iosOriginalImportMatched
        } catch {
            importMessage = L10n.iosOriginalImportFailed(String(describing: error))
        }
    }

    private func downloadOriginal() async {
        let cfg = WebDAVSettingsStore().load()
        let storage = SecurityFrameworkKeyStorage(service: SecurityFrameworkKeyStorage.webdavService)
        guard let config = cfg, !config.username.isEmpty,
              let password = try? storage.readKey(account: config.username), !password.isEmpty else {
            await MainActor.run { importMessage = L10n.iosWebDAVNotConfigured }
            downloading = false
            return
        }
        let username = config.username
        // 书库根取设置里的远端目录（WebDAVSettings 规则 remoteDir 即库根）。
        // 删 `?? "/"` 死配置降级处理——规则缺失/根为空白一律
        // fail-closed 如实报「未配置」，绝不静默退回云盘根（旧降级处理会从
        // 服务器根拼 rel_path 下载，指错位置且掩盖配置缺失）。
        guard let configuredRoot = config.rules.first?.remoteDir,
              !configuredRoot.trimmingCharacters(in: .whitespaces).isEmpty else {
            await MainActor.run {
                importMessage = L10n.iosWebDAVLibraryRootMissing
            }
            downloading = false
            return
        }
        let root = configuredRoot
        do {
            try await model.downloadOriginal(book: book, libraryRoot: root,
                                             serverBase: config.serverBase,
                                             username: username, password: password)
            await MainActor.run { importMessage = L10n.iosOriginalDownloadOK }
        } catch {
            await MainActor.run { importMessage = L10n.iosOriginalDownloadFailed(String(describing: error)) }
        }
        downloading = false
    }
}

/// 阅读器容器：PDFKit 视图 + Chrome（批注/涂画/回传入口按能力装配）。
struct ReaderContainerView: View {
    let book: IndexStore.BookRow
    let pdfURL: URL

    var body: some View {
        ReaderChromeView(book: book, pdfURL: pdfURL)
    }
}
