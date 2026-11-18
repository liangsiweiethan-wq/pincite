import Foundation
import CryptoKit
import os

// MARK: - 索引上传器（Mac 主库 → 用户自备 WebDAV 快照仓）

/// 一次上传会话的产出（设置页状态行与审计共用基准）。
public struct WebDAVUploadOutcome: Equatable {
    public var volumesTotal: Int
    public var volumesUploaded: Int
    public var volumesSkipped: Int
    public var totalBytes: Int64
    public var durationSeconds: Double
    /// 清理阶段删除的远端文件名（cleanupEnabled=false 恒空）。
    public var deletedRemotes: [String]
    /// 清理失败原因（提交已完成，清理失败不回滚上传）。
    public var cleanupError: String?

    public init(volumesTotal: Int, volumesUploaded: Int, volumesSkipped: Int,
                totalBytes: Int64, durationSeconds: Double,
                deletedRemotes: [String] = [], cleanupError: String? = nil) {
        self.volumesTotal = volumesTotal
        self.volumesUploaded = volumesUploaded
        self.volumesSkipped = volumesSkipped
        self.totalBytes = totalBytes
        self.durationSeconds = durationSeconds
        self.deletedRemotes = deletedRemotes
        self.cleanupError = cleanupError
    }
}

/// buildSnapshot 产物：manifest（已写 workDir/manifest.json）+ 分卷文件。
public struct WebDAVIndexSnapshot {
    public let manifest: WebDAVIndexManifest
    public let workDirectory: URL
    /// 分卷前整快照文件的 sha256（分卷 roundtrip 校验用；不进 manifest）。
    public let assembledSHA256: String

    public func volumeURL(_ name: String) -> URL { workDirectory.appendingPathComponent(name) }
    public var manifestFileURL: URL { workDirectory.appendingPathComponent("manifest.json") }
}

public enum WebDAVIndexUploader {
    private static let log = Logger(subsystem: "com.example.literaturesearch.app", category: "webdav-upload")

    /// 单卷上限，初值 1 GiB；按目标服务的单文件限制调整此常量。
    /// var 仅供合成测试调小以构造多卷场景，运行路径不修改。
    public static var maxVolumeBytes: Int64 = 1 << 30
    /// 分卷 PUT 之间最小间隔（rclone pacer 惯例初值 10ms，防限流）。
    static var volumePutIntervalNanoseconds: UInt64 = 10_000_000
    public static let maxVerifyAttempts = 3
    static var verifyRetryBackoffNanoseconds: UInt64 = 200_000_000
    /// 安全约束：单次运行 DELETE 总数上限。
    public static let maxDeletesPerRun = 8
    /// 安全约束：保留最近 N 份旧快照（其余才可进候选）。
    public static let keptOldSnapshots = 2

    /// 快照组装临时名（固定名，已存在则先清再建；`.tmp` 后缀天然不过
    /// 上传白名单正则，永不生效为快照）。
    public static func snapshotTempURL(in workDir: URL) -> URL {
        workDir.appendingPathComponent("index-snapshot-assembly.tmp")
    }

    // MARK: VACUUM INTO 快照 + 分卷 + manifest

    /// 对源库执行且仅执行 `VACUUM INTO`（源库零写），整文件 sha256，
    /// 超限字节分卷，写 manifest。阻塞调用（App 层自行包后台）。
    public static func buildSnapshot(dbPath: URL, workDir: URL, appVersion: String) throws -> WebDAVIndexSnapshot {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath.path) else {
            throw WebDAVError.localTargetUnavailable(dbPath.path)
        }
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let tmp = snapshotTempURL(in: workDir)
        // 目标已存在先清再建（VACUUM INTO 对已存在目标文件直接报错）。
        if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
        // 源库只读：SQLITE_OPEN_READONLY 在句柄层保证拿不到
        // 写权限；RW 连接关闭时若为唯一连接会触发 WAL checkpoint 改写
        // 主库并删 -wal。只读连接不改写主库；本连接不执行任何其他语句
        // （不建表、不写 meta）；只读打开失败即 fail-closed，绝不回退。
        // 路径按 SQLite 字符串字面量转义单引号。
        let escaped = tmp.path.replacingOccurrences(of: "'", with: "''")
        let source = try SQLiteDatabase(path: dbPath.path, flags: SQLiteDatabase.readOnlyFlags)
        try source.exec("VACUUM INTO '\(escaped)'")

        let assembledSHA = try Fingerprint.sha256Hex(ofFileAt: tmp)
        let hash16 = String(assembledSHA.prefix(16))
        let attrs = try fm.attributesOfItem(atPath: tmp.path)
        let totalSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        // 书/页计数取快照副本（基准 = IndexStore.coverageStats：books 全
        // 状态计数、pages 全量；绝不打开 IndexStore 以免触发迁移/写 meta）。
        let snapshotDB = try SQLiteDatabase(path: tmp.path)
        var bookCount = 0
        var pageCount = 0
        let bookStmt = try snapshotDB.prepare("SELECT COUNT(*) FROM books;")
        if try bookStmt.step() { bookCount = Int(bookStmt.int(0)) }
        let fulltextURL = dbPath.deletingLastPathComponent()
            .appendingPathComponent("fulltext.db")
        var fulltextAssembled: URL? = nil
        if fm.fileExists(atPath: fulltextURL.path) {
            let ftTmp = workDir.appendingPathComponent(
                "fulltext-tmp-\(UUID().uuidString).sqlite")
            if fm.fileExists(atPath: ftTmp.path) { try fm.removeItem(at: ftTmp) }
            let ftEscaped = ftTmp.path.replacingOccurrences(of: "'", with: "''")
            let ftSource = try SQLiteDatabase(path: fulltextURL.path,
                                              flags: SQLiteDatabase.readOnlyFlags)
            try ftSource.exec("VACUUM INTO '\(ftEscaped)'")
            fulltextAssembled = ftTmp
            let ftDB = try SQLiteDatabase(path: ftTmp.path)
            if let stmt = try? ftDB.prepare("SELECT COUNT(*) FROM pages;"),
               (try? stmt.step()) == true {
                pageCount = Int(stmt.int(0))
            }
        }
        if pageCount == 0,
           let pageStmt = try? snapshotDB.prepare("SELECT COUNT(*) FROM pages;"),
           (try? pageStmt.step()) == true {
            pageCount = Int(pageStmt.int(0))
        }

        // 分卷：超上限按定长字节切开；末卷可短。字节分卷依据
        // 「手机侧按 order 组装」的字节拼接语义（与分卷规则
        // 措辞有出入，此处以实现行为为准。
        var files = try splitVolumes(assembledAt: tmp, workDir: workDir,
                                     hash16: hash16, volumeCap: maxVolumeBytes)
        if let ftAssembled = fulltextAssembled {
            let ftSHA = try Fingerprint.sha256Hex(ofFileAt: ftAssembled)
            let ftFiles = try splitVolumes(assembledAt: ftAssembled, workDir: workDir,
                                           hash16: String(ftSHA.prefix(16)),
                                           volumeCap: maxVolumeBytes,
                                           namePrefix: "fulltext-")
            let orderOffset = files.count
            files += ftFiles.map { WebDAVIndexManifest.FileEntry(
                name: $0.name, sha256: $0.sha256, size: $0.size, order: $0.order + orderOffset) }
        }

        let manifest = WebDAVIndexManifest(
            schemaVersion: IndexStore.currentSchemaVersion,
            contentHash: WebDAVIndexManifest.contentHash(for: files),
            bookCount: bookCount,
            pageCount: pageCount,
            createdAt: WebDAVIndexManifest.iso8601UTC.string(from: Date()),
            appVersion: appVersion,
            files: files)
        try manifest.jsonData().write(to: workDir.appendingPathComponent("manifest.json"), options: .atomic)
        return WebDAVIndexSnapshot(manifest: manifest, workDirectory: workDir, assembledSHA256: assembledSHA)
    }

    /// 字节分卷（internal：合成测试以任意字节负载直接断言固定上限语义）。
    /// 有界切写：每轮只读 `min(readChunk, 剩余额度)`，保证每卷 size ≤ 上限
    /// （上限小于读块时也成立）；恰为上限整数倍时不落 0 字节空尾卷。
    /// 总量 ≤ 上限 → 单卷（原名 index-<hash16>.sqlite，整件改名）。
    static func splitVolumes(assembledAt tmp: URL, workDir: URL, hash16: String,
                             volumeCap: Int64,
                             namePrefix: String = "index-") throws -> [WebDAVIndexManifest.FileEntry] {
        precondition(volumeCap > 0, "卷上限必须为正")
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: tmp.path)
        let totalSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        var files: [WebDAVIndexManifest.FileEntry] = []

        func closeCurrent(_ current: inout FileHandle?, _ currentURL: inout URL?,
                          _ partBytes: Int64, _ order: inout Int) throws {
            guard let url = currentURL else { return }
            try current?.close()
            current = nil
            let size = ((try? fm.attributesOfItem(atPath: url.path)).flatMap {
                ($0[.size] as? NSNumber)?.int64Value
            } ?? partBytes)
            files.append(.init(name: url.lastPathComponent,
                               sha256: try Fingerprint.sha256Hex(ofFileAt: url),
                               size: size, order: order))
            order += 1
            currentURL = nil
        }

        if totalSize <= volumeCap {
            let name = "\(namePrefix)\(hash16).sqlite"
            let target = workDir.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: tmp, to: target)
            files.append(.init(name: name,
                               sha256: try Fingerprint.sha256Hex(ofFileAt: target),
                               size: totalSize, order: 1))
            return files
        }

        let reader = try FileHandle(forReadingFrom: tmp)
        defer { try? reader.close() }
        let readChunk = 1 << 20   // 1 MiB 读块上限；实际读量受卷剩余额度约束
        var order = 1
        var partBytes: Int64 = 0
        var current: FileHandle? = nil
        var currentURL: URL? = nil
        defer { try? current?.close() }
        while true {
            if current == nil {
                let name = "\(namePrefix)\(hash16)-part\(order).sqlite"
                let url = workDir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                fm.createFile(atPath: url.path, contents: Data())
                current = try FileHandle(forWritingTo: url)
                currentURL = url
                partBytes = 0
            }
            // 循环顶不变式：partBytes < volumeCap（达上限即闭卷），want ≥ 1。
            let want = Int(min(Int64(readChunk), volumeCap - partBytes))
            let chunk = try reader.read(upToCount: want) ?? Data()
            guard !chunk.isEmpty else { break }
            try current?.write(contentsOf: chunk)
            partBytes += Int64(chunk.count)
            if partBytes >= volumeCap { try closeCurrent(&current, &currentURL, partBytes, &order) }
        }
        if let url = currentURL {
            if partBytes > 0 {
                // 末卷：可短于上限。
                try closeCurrent(&current, &currentURL, partBytes, &order)
            } else {
                // 恰为上限整数倍：不落 0 字节空尾卷。
                try current?.close()
                current = nil
                try? fm.removeItem(at: url)
                currentURL = nil
            }
        }
        try? fm.removeItem(at: tmp)
        return files
    }

    static func snapshotID(ofName name: String) -> String? {
        let prefix: String
        if name.hasPrefix("index-") { prefix = "index-" }
        else if name.hasPrefix("fulltext-") { prefix = "fulltext-" }
        else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        guard let end = name.index(start, offsetBy: 16, limitedBy: name.endIndex) else { return nil }
        return String(name[start..<end])
    }

    // MARK: uploadAll 主序列（manifest 为提交点，无部分提交）

    /// 主上传序列。cleanupEnabled 仅在显式开关打开时于成功末尾运行清理。
    public static func uploadAll(client: WebDAVClient, snapshot: WebDAVIndexSnapshot,
                                 cleanupEnabled: Bool = false,
                                 audit: WebDAVUploadAuditStore? = nil) async throws -> WebDAVUploadOutcome {
        let started = Date()
        try await client.makeCollection(path: WebDAVIndexPaths.uploadPrefixDirectory)

        let remoteManifest = try await fetchRemoteManifest(client: client)
        let referencedNames = Set(remoteManifest?.files.map(\.name) ?? [])

        let files = snapshot.manifest.files.sorted { $0.order < $1.order }
        var uploaded = 0
        var skipped = 0
        for entry in files {
            let remotePath = WebDAVIndexPaths.uploadPrefixDirectory + "/" + entry.name
            if referencedNames.contains(entry.name) {
                // 安全约束：现行 manifest 已引用的卷名禁直 PUT。同 hash（同
                // 内容⇒同名）且 size 一致 → 幂等跳过；不一致 = 远端异常态，
                // fail-closed 报错交用户处置（新内容必生成新 hash16 名，
                // 正常流程永不撞名； 又禁 MOVE 替换，故不做覆盖）。
                let remoteSize = try await remoteSize(client: client, fileName: entry.name)
                guard remoteSize == entry.size else {
                    throw WebDAVError.forbiddenRemotePath(
                        "远端已引用 \(entry.name) 但 size 不符（远端 \(remoteSize) / 本地 \(entry.size)）；拒绝覆盖，请人工处置")
                }
                skipped += 1
                log.info("skip \(entry.name, privacy: .public) bytes \(entry.size, privacy: .public)")
                continue
            }
            var lastError: Error?
            for attempt in 1...maxVerifyAttempts {
                do {
                    try await client.upload(fileURL: snapshot.volumeURL(entry.name), to: remotePath)
                    let actual = try await remoteSize(client: client, fileName: entry.name)
                    guard actual == entry.size else {
                        throw WebDAVError.downloadSizeMismatch(expected: entry.size, actual: actual,
                                                               context: "PUT 后复核 \(entry.name)")
                    }
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt < maxVerifyAttempts {
                        try await Task.sleep(nanoseconds: verifyRetryBackoffNanoseconds * UInt64(attempt))
                    }
                }
            }
            if let lastError { throw lastError }   // 整体失败：manifest 不 PUT
            uploaded += 1
            log.info("PUT \(entry.name, privacy: .public) bytes \(entry.size, privacy: .public) ok")
            if entry.order != files.last?.order {
                try await Task.sleep(nanoseconds: volumePutIntervalNanoseconds)
            }
        }

        try await client.upload(fileURL: snapshot.manifestFileURL,
                                to: WebDAVIndexPaths.uploadPrefixDirectory + "/manifest.json")
        log.info("PUT manifest.json ok")

        let duration = Date().timeIntervalSince(started)
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        audit?.append(kind: "upload", result: "ok", volumes: files.count,
                      bytes: totalBytes, durationMs: duration * 1000)

        var deleted: [String] = []
        var cleanupError: String?
        if cleanupEnabled {
            do {
                deleted = try await cleanupUploadDir(client: client, audit: audit)
            } catch {
                cleanupError = String(describing: error)
                log.error("cleanup failed: \(cleanupError!, privacy: .public)")
            }
        }
        return WebDAVUploadOutcome(volumesTotal: files.count, volumesUploaded: uploaded,
                                   volumesSkipped: skipped, totalBytes: totalBytes,
                                   durationSeconds: duration, deletedRemotes: deleted,
                                   cleanupError: cleanupError)
    }

    /// 前缀目录内某文件当前远端 size（PROPFIND；缺失 = -1）。
    static func remoteSize(client: WebDAVClient, fileName: String) async throws -> Int64 {
        let listing = try await client.list(directory: WebDAVIndexPaths.uploadPrefixDirectory)
        return listing.first { !$0.isDirectory && $0.fileName == fileName }?.size ?? -1
    }

    public static func fetchRemoteManifest(client: WebDAVClient) async throws -> WebDAVIndexManifest? {
        try await fetchRemoteState(client: client).manifest
    }

    /// 同一次 PROPFIND 取「现行 manifest + 前缀列表」（二次核对复用，
    /// 避免引用集与在场性来自两个时刻）。
    static func fetchRemoteState(client: WebDAVClient) async throws
        -> (manifest: WebDAVIndexManifest?, listing: [WebDAVResource]) {
        let listing = try await client.list(directory: WebDAVIndexPaths.uploadPrefixDirectory)
        guard let entry = listing.first(where: { !$0.isDirectory && $0.fileName == "manifest.json" }) else {
            return (nil, listing)
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("webdav-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await client.download(remotePath: WebDAVIndexPaths.uploadPrefixDirectory + "/manifest.json",
                                  to: tmp, expectedBytes: entry.sizeDeclared ? entry.size : nil)
        let data = try Data(contentsOf: tmp)
        return (try WebDAVIndexManifest.parse(data), listing)
    }

    // MARK: fail-closed 旧快照清理

    /// 清理上传前缀内「不被现行 manifest 引用」的旧快照卷。
    public static func cleanupUploadDir(client: WebDAVClient,
                                        audit: WebDAVUploadAuditStore?) async throws -> [String] {
        guard let manifest = try await fetchRemoteManifest(client: client) else {
            throw WebDAVError.forbiddenRemotePath("清理中止：远端无现行 manifest（fail-closed，零删除）")
        }
        // 门 3：引用集为空集 = manifest 异常态，宁可不删。
        let volumeNames = manifest.files.map(\.name)
        guard !volumeNames.isEmpty else {
            throw WebDAVError.forbiddenRemotePath("清理中止：现行 manifest 引用集为空（fail-closed，零删除）")
        }
        let referenced = Set(volumeNames).union(["manifest.json"])

        let listing = try await client.list(directory: WebDAVIndexPaths.uploadPrefixDirectory)
        let managed = listing.filter { !$0.isDirectory && WebDAVIndexPaths.isAllowedRemoteName($0.fileName) }
        // 白名单正则同时是删除护栏：.tmp-* 等杂名永不进候选。

        // 旧快照分组（引用集之外），按组内最新 mtime 降序，保留最近 N 组。
        var groups: [String: [WebDAVResource]] = [:]
        for res in managed where !referenced.contains(res.fileName) {
            if let id = snapshotID(ofName: res.fileName) {
                groups[id, default: []].append(res)
            }
        }
        let kept = Set(groups.values
            .sorted { groupTime($0) > groupTime($1) }
            .prefix(keptOldSnapshots)
            .flatMap { $0.map(\.fileName) })
        let candidates = groups.values
            .flatMap { $0 }
            .filter { !kept.contains($0.fileName) }
            .sorted { groupTime([$0]) < groupTime([$1]) }   // 最旧先删
            .prefix(maxDeletesPerRun)

        let (freshManifest, freshListing) = try await fetchRemoteState(client: client)
        guard let fresh = freshManifest else {
            throw WebDAVError.forbiddenRemotePath("清理中止：二次核对时现行 manifest 缺席（fail-closed，零删除）")
        }
        guard !fresh.files.isEmpty else {
            throw WebDAVError.forbiddenRemotePath("清理中止：二次核对时引用集为空（fail-closed，零删除）")
        }
        let referencedNow = Set(fresh.files.map(\.name)).union(["manifest.json"])
        let freshNames = Set(freshListing.filter { !$0.isDirectory }.map(\.fileName))
        var deleted: [String] = []
        for candidate in candidates {
            guard freshNames.contains(candidate.fileName),
                  !referencedNow.contains(candidate.fileName) else { continue }
            try await client.delete(path: WebDAVIndexPaths.uploadPrefixDirectory + "/" + candidate.fileName)
            deleted.append(candidate.fileName)
            audit?.append(kind: "cleanup", result: "deleted", fileName: candidate.fileName)
            log.info("DELETE \(candidate.fileName, privacy: .public) bytes \(candidate.size, privacy: .public) ok")
        }
        return deleted
    }

    private static func groupTime(_ resources: [WebDAVResource]) -> Date {
        resources.compactMap(\.lastModified).max() ?? .distantPast
    }
}

// MARK: - 操作审计（环形 5 条；AppSupport/LiteratureSearch/ 下）

public struct WebDAVUploadAuditEntry: Codable, Equatable, Identifiable {
    public var id: String
    /// ISO8601 UTC。
    public var at: String
    /// "upload"（一次上传会话一条）| "cleanup"（每删一文件一条）。
    public var kind: String
    /// 结果码："ok" | "deleted" | "failed"…
    public var result: String
    public var volumes: Int?
    public var bytes: Int64?
    public var durationMs: Double?
    public var fileName: String?
    public var detail: String?

    public init(id: String = UUID().uuidString, at: String, kind: String, result: String,
                volumes: Int? = nil, bytes: Int64? = nil, durationMs: Double? = nil,
                fileName: String? = nil, detail: String? = nil) {
        self.id = id
        self.at = at
        self.kind = kind
        self.result = result
        self.volumes = volumes
        self.bytes = bytes
        self.durationMs = durationMs
        self.fileName = fileName
        self.detail = detail
    }
}

/// 环形审计存储：最新在前，最多保留 capacity 条；坏档 fail-closed 回空。
/// 绝不记录完整路径正文与凭据（文件名/计数/耗时/结果码为全部承载面）。
public final class WebDAVUploadAuditStore {
    public static let fileName = "webdav-upload-audit.json"
    public static let capacity = 5

    public let fileURL: URL

    public init(directory: URL = AppSupportPaths.appDirectory()) {
        self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    public func entries() -> [WebDAVUploadAuditEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([WebDAVUploadAuditEntry].self, from: data) else {
            return []
        }
        return list
    }

    public func append(kind: String, result: String, volumes: Int? = nil, bytes: Int64? = nil,
                       durationMs: Double? = nil, fileName: String? = nil, detail: String? = nil) {
        var list = entries()
        list.insert(WebDAVUploadAuditEntry(
            at: WebDAVIndexManifest.iso8601UTC.string(from: Date()),
            kind: kind, result: result, volumes: volumes, bytes: bytes,
            durationMs: durationMs, fileName: fileName, detail: detail), at: 0)
        if list.count > Self.capacity { list = Array(list.prefix(Self.capacity)) }
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - 上传选项（UserDefaults；设置页显式开关）

public enum WebDAVUploadOptions {
    /// 「索引重建后自动上传」——默认关闭，仅在新索引就绪之后执行。
    public static let autoUploadDefaultsKey = "webdavAutoUploadAfterRebuild"
    /// 「上传后清理未引用旧快照」——默认关（保持无删除语义边界）。
    public static let cleanupDefaultsKey = "webdavUploadCleanupEnabled"

    public static func autoUploadEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: autoUploadDefaultsKey) as? Bool ?? false
    }
    public static func cleanupEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: cleanupDefaultsKey) as? Bool ?? false
    }
    public static func setAutoUpload(_ on: Bool, defaults: UserDefaults) {
        defaults.set(on, forKey: autoUploadDefaultsKey)
    }
    public static func setCleanup(_ on: Bool, defaults: UserDefaults) {
        defaults.set(on, forKey: cleanupDefaultsKey)
    }
}
