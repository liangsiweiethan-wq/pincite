import Foundation

// MARK: - WebDAV 同步引擎（其他设备下载的文献经 WebDAV 进入本库）

public struct WebDAVSyncRule: Codable, Equatable {
    /// 远端目录（相对 serverBase，如 /Books）。
    public var remoteDir: String
    /// 本地目标根（该远端目录的落点）。
    public var localRoot: URL

    public init(remoteDir: String, localRoot: URL) {
        self.remoteDir = remoteDir
        self.localRoot = localRoot
    }
}

public struct WebDAVSyncConfig: Codable {
    public var serverBase: String      // https://dav.example.com/webdav
    public var username: String
    public var rules: [WebDAVSyncRule]
    /// 只拉这些扩展名（小写带点）；空 = 全部。
    public var extensions: [String]

    public init(serverBase: String, username: String, rules: [WebDAVSyncRule], extensions: [String] = [".pdf"]) {
        self.serverBase = serverBase
        self.username = username
        self.rules = rules
        self.extensions = extensions
    }
}

/// dry-run 预演清单项：记录待下载文件的远端路径、文件名和大小。
public struct WebDAVPendingDownload: Equatable {
    public var remotePath: String
    public var fileName: String
    public var size: Int64

    public init(remotePath: String, fileName: String, size: Int64) {
        self.remotePath = remotePath
        self.fileName = fileName
        self.size = size
    }
}

public struct WebDAVSyncOutcome: Equatable {
    public var downloaded: [String]
    public var skipped: Int
    public var failed: [String]
    /// 仅 dryRun=true 时填充：将下载清单（路径/大小）；真实同步恒为空。
    public var pendingDownloads: [WebDAVPendingDownload]

    public init(downloaded: [String] = [], skipped: Int = 0, failed: [String] = [],
                pendingDownloads: [WebDAVPendingDownload] = []) {
        self.downloaded = downloaded
        self.skipped = skipped
        self.failed = failed
        self.pendingDownloads = pendingDownloads
    }
}

public final class WebDAVSyncEngine {
    struct LedgerEntry: Codable, Equatable {
        var size: Int64
        var mtime: Double?
    }

    /// 账本默认与目标根同放（.webdav-sync-ledger.json）。
    public static func ledgerURL(for rule: WebDAVSyncRule) -> URL {
        rule.localRoot.appendingPathComponent(".webdav-sync-ledger.json")
    }

    private static func loadLedger(_ url: URL) -> [String: LedgerEntry] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: LedgerEntry].self, from: data) else { return [:] }
        return raw
    }

    private static func saveLedger(_ url: URL, _ ledger: [String: LedgerEntry]) {
        if let data = try? JSONEncoder().encode(ledger) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 同步一条规则。阻塞调用（CLI 串行用）；App 层自行包后台。
    ///
    /// dryRun=true：与真实同步同一判定基准（扩展名过滤、
    /// 账本+本地存在性比对），但只返回「将下载清单（路径/大小）」，不下载、
    /// 不落盘、不写账本；真实同步的既有调用点零改动（默认 false）。
    public static func sync(rule: WebDAVSyncRule, config: WebDAVSyncConfig,
                            password: String, client: WebDAVClient? = nil,
                            dryRun: Bool = false) async throws -> WebDAVSyncOutcome {
        var outcome = WebDAVSyncOutcome()
        let fm = FileManager.default
        guard let rootStat = try? fm.attributesOfItem(atPath: rule.localRoot.path),
              rootStat[.type] as? FileAttributeType == .typeDirectory else {
            throw WebDAVError.localTargetUnavailable(rule.localRoot.path)
        }
        let base = try WebDAVClient.validatedBase(config.serverBase)
        let client = client ?? WebDAVClient(serverBase: base, username: config.username, password: password)
        let remote = try await client.list(directory: rule.remoteDir)
        let exts = Set(config.extensions.map { $0.lowercased() })
        let ledgerURL = Self.ledgerURL(for: rule)
        var ledger = Self.loadLedger(ledgerURL)

        for res in remote where !res.isDirectory {
            let ext = (res.fileName as NSString).pathExtension.lowercased()
            if !exts.isEmpty, !exts.contains(".\(ext)") { outcome.skipped += 1; continue }
            let local = rule.localRoot.appendingPathComponent(res.fileName)
            let prior = ledger[res.path]
            // 无 mtime 的远端（部分服务器）退化为 size 比对；有 mtime 则双比对。
            let unchanged = prior != nil
                && prior?.size == res.size
                && (res.lastModified == nil || (prior?.mtime != nil
                    && prior?.mtime == res.lastModified?.timeIntervalSince1970))
            if fm.fileExists(atPath: local.path) {
                if unchanged {
                    outcome.skipped += 1
                } else {
                    outcome.failed.append(WebDAVError.localFileExists(res.fileName).description)
                }
                continue
            }
            if dryRun {
                // 预演：只记账将下载项，绝不写盘、绝不写账本。
                outcome.pendingDownloads.append(WebDAVPendingDownload(
                    remotePath: res.path, fileName: res.fileName, size: res.size))
                continue
            }
            do {
                try await client.download(remotePath: res.path, to: local,
                                          expectedBytes: res.sizeDeclared ? res.size : nil)
                ledger[res.path] = LedgerEntry(size: res.size, mtime: res.lastModified?.timeIntervalSince1970)
                outcome.downloaded.append(res.fileName)
            } catch {
                outcome.failed.append("\(res.fileName): \(error)")
            }
        }
        if dryRun { return outcome }   // 预演不写账本（下次真实同步按原账本重算）
        Self.saveLedger(ledgerURL, ledger)
        return outcome
    }
}
