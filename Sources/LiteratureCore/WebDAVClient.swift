import Foundation
import Darwin

// MARK: - WebDAV 客户端（通过 WebDAV 服务同步）

public struct WebDAVResource: Equatable {
    /// 完整 URL 路径（decode 后）。
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    /// false = 服务器未回 getcontentlength（此时 size 无意义，不得用作
    /// 下载声明值——双上限只对「确有声明」的条目生效）。
    public var sizeDeclared: Bool
    /// 远端修改时间（epoch 秒；解析失败为 nil）。
    public var lastModified: Date?

    public init(path: String, isDirectory: Bool, size: Int64, lastModified: Date?,
                sizeDeclared: Bool = true) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.sizeDeclared = sizeDeclared
        self.lastModified = lastModified
    }

    /// 文件名（末段）。
    public var fileName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

public enum WebDAVError: Error, CustomStringConvertible {
    case badURL(String)
    /// 安全约束/serverBase 被拒。只携带 scheme/host 与拒绝原因，绝不
    /// 回显地址原文——原文可能含 user:password@ 与 query，回显会经状态
    //行/审计落盘（凭据纪律）。
    case insecureBase(scheme: String?, host: String?, reason: String)
    case httpStatus(Int, String)
    case credentialMissing
    case localTargetUnavailable(String)
    case localFileExists(String)
    /// 安全约束：目标不在上传白名单前缀/命名内（未发起任何网络请求）。
    case forbiddenRemotePath(String)
    /// 安全约束：下载超出绝对上限（未落盘）。
    case downloadTooLarge(String)
    /// 安全约束：实际字节数与 PROPFIND/manifest 声明值不符。
    case downloadSizeMismatch(expected: Int64, actual: Int64, context: String)

    public var description: String {
        switch self {
        case .badURL(let u): return "WebDAV URL 无效: \(u)"
        case .insecureBase(let scheme, let host, let reason):
            return "WebDAV 服务器地址被拒绝（\(reason)）：scheme=\(scheme ?? "无") host=\(host ?? "无")。" +
                   "须为 HTTPS 且不得内嵌 user:password@（地址原文不回显，防凭据入日志/审计）"
        case .httpStatus(let code, let ctx): return "WebDAV HTTP \(code)（\(ctx)）"
        case .credentialMissing: return "WebDAV 凭据缺失（需要用户名+密码/appPassword）"
        case .localTargetUnavailable(let p): return "本地目标目录不可用: \(p)"
        case .localFileExists(let name): return "本地已有同名文件，已保留原件：\(name)"
        case .forbiddenRemotePath(let p): return "目标不在上传白名单内（拒绝）: \(p)"
        case .downloadTooLarge(let ctx): return "下载超过大小上限（拒绝）: \(ctx)"
        case .downloadSizeMismatch(let expected, let actual, let ctx):
            return "下载大小与声明不符（安全约束）：声明 \(expected) 实际 \(actual)（\(ctx)）"
        }
    }
}

/// 安全约束/重定向守卫（纯函数，单测断言固定）。
/// 目标必须 HTTPS 且与源同 host 同端口（同 origin）；其余一律拒绝。
public enum RedirectGuard {
    public static func isAllowed(from: URL?, to: URL?) -> Bool {
        guard let from, let to else { return false }
        guard to.scheme?.lowercased() == "https" else { return false }
        guard let fromHost = from.host?.lowercased(),
              let toHost = to.host?.lowercased(), fromHost == toHost else { return false }
        return effectivePort(from) == effectivePort(to)
    }

    /// 显式端口缺省按 scheme 的默认端口。
    static func effectivePort(_ url: URL) -> Int {
        if let p = url.port { return p }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }
}

/// URLSessionTaskDelegate：willPerformHTTPRedirection 处调 RedirectGuard
/// （与 AIAssistantService 的同名 delegate 职责不同源，命名带 WebDAV 前缀）。
final class WebDAVRedirectGuardDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if RedirectGuard.isAllowed(from: task.originalRequest?.url, to: request.url) {
            completionHandler(request)
        } else {
            completionHandler(nil)   // 取消 → 调用方收到错误，凭据不跨域
        }
    }
}

public class WebDAVClient {
    public var serverBase: URL        // 如 https://dav.example.com/webdav
    public var username: String
    public var password: String       // appPassword；调用方从 Keychain 取
    public var timeout: TimeInterval

    /// 安全约束/serverBase 代码级强制——scheme 必须 https（大小写不
    /// 敏感，按 URL 标准）、host 非空、不得内嵌 user:password@ userinfo。
    /// 全部构造点（引擎/App/CLI）必须先过这里；旧版「构造失败落占位假
    /// 域名降级处理」已废除（校验失败=明确报错，绝不静默换地址）。
    public static func validatedBase(_ string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let scheme = url.scheme, scheme.lowercased() == "https",
           let host = url.host, !host.isEmpty,
           url.user == nil, url.password == nil {
            return url
        }
        // 拒绝原因只做分类判定，错误负载仅含 scheme/host——地址原文
        // （可能内嵌凭据与 query）永不进入错误串/状态行/审计。
        // scheme 回显仅限 http/https：无 scheme 输入
        // （如 alice:pw@host）被 URL 解析为 scheme="alice"——正是用户名
        // 串，不在白名单内则不回显。
        let parsed = URL(string: trimmed)
        let schemeEcho: String? = ["http", "https"].contains(parsed?.scheme?.lowercased() ?? "")
            ? parsed?.scheme : nil
        let reason: String
        if parsed == nil {
            reason = "地址无法解析"
        } else if parsed?.user != nil || parsed?.password != nil {
            reason = "内嵌 userinfo"
        } else if parsed?.scheme?.lowercased() != "https" {
            reason = "非 HTTPS"
        } else {
            reason = "host 缺失"
        }
        throw WebDAVError.insecureBase(scheme: schemeEcho, host: parsed?.host, reason: reason)
    }

    /// 自持会话（弃用 URLSession.shared）：挂重定向守卫，禁缓存。
    /// 客户端按动作短生命周期创建，会话单例共享（无状态 delegate，
    /// 不持客户端引用；与 URLSession.shared 同为进程内常驻对象）。
    static let transferSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: WebDAVRedirectGuardDelegate(), delegateQueue: nil)
    }()

    /// 安全约束：下载绝对上限 8 GiB。上限要容得下合法的大型索引与单书，
    /// 只拦截失控响应。
    public static let absoluteDownloadCap: Int64 = 8 << 30
    /// 安全约束：「校验失败丢弃重下」重试上限（含网络错误；常量断言固定）。
    public static let maxDownloadAttempts = 3
    /// 重试指数退避基值（1×/2×/3×）。测试可调小（仅测试写）。
    static var downloadRetryBackoffNanoseconds: UInt64 = 100_000_000
    /// 流式写盘的缓冲粒度。
    static let streamFlushBytes = 1 << 20

    public init(serverBase: URL, username: String, password: String, timeout: TimeInterval = 60) {
        self.serverBase = serverBase
        self.username = username
        self.password = password
        self.timeout = timeout
    }

    static func withTrailingSlash(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let p = comps.percentEncodedPath
        if !p.hasSuffix("/") { comps.percentEncodedPath = p + "/" }
        return comps.url ?? url
    }

    /// internal（合成测试经 @testable 断言方法名/头；生产面不公开）。
    func request(method: String, url: URL, depth: Int?) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        let auth = Data("\(username):\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        if let depth { req.setValue(String(depth), forHTTPHeaderField: "Depth") }
        return req
    }

    /// 受管上传前缀注册表
    /// - index（既有）：WebDAVIndexPaths 前缀 + 白名单正则，原样；
    /// - inbox（新增）：ShareInbox 前缀 + 文件名正则。
    /// WebDAVIndexManifest.swift 的白名单正则与 contentHash 规则零触碰
    /// （约束：只读复用）；本表只是把「受管上传面」从单前缀扩成两个。
    static let managedUploadTargets: [(segments: [String], nameAllowed: (String) -> Bool)] = [
        (WebDAVIndexPaths.uploadPrefixSegments, WebDAVIndexPaths.isAllowedRemoteName),
        (ShareInbox.prefixSegments, ShareInbox.isAllowedFileName),
    ]

    /// 远端路径（相对 serverBase）→ 受管前缀 + 白名单校验后的段列表。
    /// 任一受管前缀（含其自身前缀段——供 MKCOL 逐级建集合）匹配即放行，
    /// 文件名段用该前缀自己的白名单；全不匹配 = 违例。
    static func validatedManagedSegments(_ remotePath: String) -> [String]? {
        let decoded = remotePath.removingPercentEncoding ?? remotePath
        let segments = decoded.split(separator: "/").map(String.init)
        for target in managedUploadTargets {
            let prefix = target.segments
            if segments.count >= prefix.count,
               Array(segments.prefix(prefix.count)) == prefix {
                if segments.count == prefix.count { return segments }        // 前缀目录本身（MKCOL）
                if segments.count == prefix.count + 1,
                   target.nameAllowed(segments.last!) {
                    return segments
                }
                return nil   // 前缀下更深路径/多段文件名 → 违例
            }
        }
        return nil
    }

    /// 远端路径（相对 serverBase）→ 白名单校验后的 URL（上传面唯一通道）。
    /// 违例抛 forbiddenRemotePath，绝不发起网络请求。
    func validatedUploadURL(_ remotePath: String) throws -> URL {
        guard let segments = Self.validatedManagedSegments(remotePath),
              let url = WebDAVIndexPaths.remoteURL(base: serverBase, segments: segments) else {
            throw WebDAVError.forbiddenRemotePath(remotePath)
        }
        return url
    }

    /// 通用远端路径 → 编码 URL（下载方向：目录由用户配置，不限于上传
    /// 前缀，但仍逐段编码+拒绝穿越；行为修正：原裸拼接对中文
    /// 目录本就不可靠）。
    func encodedRemoteURL(_ remotePath: String) throws -> URL {
        let decoded = remotePath.removingPercentEncoding ?? remotePath
        let segments = decoded.split(separator: "/").map(String.init)
        guard let url = WebDAVIndexPaths.remoteURL(base: serverBase, segments: segments) else {
            throw WebDAVError.badURL(remotePath)
        }
        return url
    }

    /// 列目录（depth 1）。返回子资源（不含目录本身）。
    public func list(directory: String) async throws -> [WebDAVResource] {
        let trimmed = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        let url = try encodedRemoteURL(trimmed)
        // 目录语义：末尾补斜杠（既有服务器约定；组件级拼接，不再裸拼串）。
        let dirURL = Self.withTrailingSlash(url)
        let (data, response) = try await Self.transferSession.data(for: request(method: "PROPFIND", url: dirURL, depth: 1))
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 207 else { throw WebDAVError.httpStatus(code, "PROPFIND \(trimmed)") }
        return try Self.parsePropfind(data, baseURL: url)
    }

    /// 下载文件到本地 URL（安全约束：流式落盘 + 双上限 + 重试上限）。
    ///
    /// expectedBytes 传 PROPFIND 声明值（引擎在 list 后已持有 res.size）：
    /// 声明值超绝对上限 → 发起请求前直接拒绝；流式接收计数超声明值或
    /// 绝对上限 → 中断抛错、丢弃半成品；收流完成后计数 ≠ 声明值 → 判
    /// 损坏。任何失败丢弃重下最多 maxDownloadAttempts 次，超限显式失败。
    /// 既有账本幂等语义零改动。
    public func download(remotePath: String, to local: URL,
                         expectedBytes: Int64? = nil,
                         absoluteCap: Int64 = WebDAVClient.absoluteDownloadCap) async throws {
        guard !FileManager.default.fileExists(atPath: local.path) else {
            throw WebDAVError.localFileExists(local.lastPathComponent)
        }
        let url = try encodedRemoteURL(remotePath)
        if let expected = expectedBytes, expected > absoluteCap {
            throw WebDAVError.downloadTooLarge("声明 \(expected) B 超绝对上限 \(absoluteCap) B（\(remotePath)）")
        }
        var lastError: Error?
        for attempt in 1...Self.maxDownloadAttempts {
            do {
                let req = request(method: "GET", url: url, depth: nil)
                let (bytes, response) = try await Self.transferSession.bytes(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard code == 200 else { throw WebDAVError.httpStatus(code, "GET \(remotePath)") }
                try await Self.consumeDownload(bytes, to: local, expectedBytes: expectedBytes,
                                               absoluteCap: absoluteCap, context: remotePath)
                return
            } catch WebDAVError.localFileExists(let name) {
                throw WebDAVError.localFileExists(name)
            } catch {
                lastError = error
                if attempt < Self.maxDownloadAttempts {
                    try await Task.sleep(nanoseconds: Self.downloadRetryBackoffNanoseconds * UInt64(attempt))
                }
            }
        }
        throw lastError ?? WebDAVError.httpStatus(-1, "GET \(remotePath)")
    }

    /// 流式消费字节流：逐块写盘累计计数，双上限即时中断，成功后原子
    /// 换名到位。internal：合成测试以合成字节流覆盖双上限/逐字节一致。
    static func consumeDownload<S: AsyncSequence>(_ bytes: S, to local: URL,
                                                  expectedBytes: Int64?, absoluteCap: Int64,
                                                  context: String) async throws
    where S.Element == UInt8 {
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let tmp = local.deletingLastPathComponent()
            .appendingPathComponent(".download-\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(streamFlushBytes)
        func flush() throws {
            guard !buffer.isEmpty else { return }
            try buffer.appendToFile(at: tmp)
            buffer.removeAll(keepingCapacity: true)
        }
        for try await byte in bytes {
            buffer.append(byte)
            received += 1
            if received > absoluteCap {
                throw WebDAVError.downloadTooLarge("绝对上限 \(absoluteCap) B（\(context)）")
            }
            if let expected = expectedBytes, received > expected {
                throw WebDAVError.downloadSizeMismatch(expected: expected, actual: received, context: context)
            }
            if buffer.count >= streamFlushBytes { try flush() }
        }
        try flush()
        if let expected = expectedBytes, received != expected {
            throw WebDAVError.downloadSizeMismatch(expected: expected, actual: received, context: context)
        }
        if received == 0 { try Data().write(to: tmp) }
        // Atomically publish the completed download only if the destination is vacant.
        guard renamex_np(tmp.path, local.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST {
                throw WebDAVError.localFileExists(local.lastPathComponent)
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSURLErrorKey: local])
        }
    }

    /// 校验-only（零网络）：白名单目标判定，供合成测试与调用方预检。
    func validatedUploadTarget(_ remotePath: String) throws -> URL {
        try validatedUploadURL(remotePath)
    }

    /// MKCOL 路径校验-only（零网络）：返回逐级段列表（每项一次 MKCOL）。
    /// 接受任一受管前缀（index/inbox）的前缀段路径——创建
    /// LiteratureSearch/sync、LiteratureSearch/sync/inbox 等逐级集合；index 前缀
    /// 行为不变。
    func mkcolSegments(_ path: String) throws -> [[String]] {
        let decoded = path.removingPercentEncoding ?? path
        let segments = decoded.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { throw WebDAVError.forbiddenRemotePath(path) }
        for target in Self.managedUploadTargets {
            let prefix = target.segments
            if segments.count <= prefix.count,
               Array(segments) == Array(prefix.prefix(segments.count)) {
                return (1...segments.count).map { Array(segments[0..<$0]) }
            }
        }
        throw WebDAVError.forbiddenRemotePath(path)
    }

    /// 上传整文件（PUT）。流式从盘发送（upload(for:fromFile:) 由
    /// URLSession 自行按文件属性设 Content-Length，不整读进内存）。
    /// 只接受 WebDAVIndexPaths 校验过的目标 URL（违例零网络调用）。
    @discardableResult
    public func upload(fileURL: URL, to remotePath: String) async throws -> Int64 {
        let url = try validatedUploadURL(remotePath)
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let (data, response) = try await Self.transferSession.upload(for: request(method: "PUT", url: url, depth: nil),
                                                                     fromFile: fileURL)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw WebDAVError.httpStatus(code, "PUT \(remotePath)")
        }
        _ = data   // 2xx 即成功；响应体不承载语义
        return size
    }

    public func move(from remotePath: String, to targetPath: String) async throws {
        let url = try validatedUploadURL(remotePath)
        let target = try validatedUploadURL(targetPath)
        var req = request(method: "MOVE", url: url, depth: nil)
        req.setValue(target.absoluteString, forHTTPHeaderField: "Destination")
        let (_, response) = try await Self.transferSession.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw WebDAVError.httpStatus(code, "MOVE \(remotePath) → \(targetPath)")
        }
    }

    /// DELETE（安全约束：仅限上传前缀内白名单名；仅由旧快照清理器调用，
    /// 且清理器自带 fail-closed 前置与 ≤8/次上限）。
    public func delete(path: String) async throws {
        let url = try validatedUploadURL(path)
        let (_, response) = try await Self.transferSession.data(for: request(method: "DELETE", url: url, depth: nil))
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw WebDAVError.httpStatus(code, "DELETE \(path)")
        }
    }

    /// MKCOL 逐级创建集合（默认=上传前缀 LiteratureSearch/sync/index/）。
    /// 但 PUT 到不存在的目录普遍 409，属实现必需
    /// 405（已存在）视为成功；只允许创建上传前缀的
    /// 前缀段，其余路径拒绝。
    public func makeCollection(path: String = WebDAVIndexPaths.uploadPrefixDirectory) async throws {
        for level in try mkcolSegments(path) {
            guard let url = WebDAVIndexPaths.remoteURL(base: serverBase, segments: level) else {
                throw WebDAVError.badURL(path)
            }
            // 集合 URL 以斜杠结尾（部分服务器要求）。
            let dirURL = Self.withTrailingSlash(url)
            let (_, response) = try await Self.transferSession.data(for: request(method: "MKCOL", url: dirURL, depth: nil))
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) || code == 405 else {
                throw WebDAVError.httpStatus(code, "MKCOL \(level.joined(separator: "/"))")
            }
        }
    }

    // MARK: PROPFIND XML 解析（multistatus response 块级拆分）

    static func parsePropfind(_ data: Data, baseURL: URL) throws -> [WebDAVResource] {
        guard let xml = String(data: data, encoding: .utf8) else {
            throw WebDAVError.httpStatus(-1, "PROPFIND 非 UTF-8 响应")
        }
        // 按 <response>…</response>（命名空间前缀不定：d: / D: / 无）切块。
        let body = xml.replacingOccurrences(of: "d:", with: "").replacingOccurrences(of: "D:", with: "")
        let chunks = body.components(separatedBy: "<response>").dropFirst()
        var out: [WebDAVResource] = []
        let base = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
        for chunk in chunks {
            let href = Self.firstTag("href", in: chunk) ?? ""
            let decoded = href.removingPercentEncoding ?? href
            let normalized = decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
            guard !decoded.isEmpty, normalized != base else { continue }   // 跳过目录自身（尾斜杠归一）
            let isDir = chunk.contains("<collection")
            // getcontentlength 缺失/不可解析 = 未声明（sizeDeclared=false，
            // size 置 0 仅为兼容字段类型；不得用作下载声明值——与「0 字节
            // 文件」不可混同）。
            let declared = Self.firstTag("getcontentlength", in: chunk).flatMap { Int64($0) }
            let size = declared ?? 0
            var mtime: Date? = nil
            if let raw = Self.firstTag("getlastmodified", in: chunk) {
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                mtime = fmt.date(from: raw)
            }
            // href 是服务器路径——统一成与请求一致的绝对路径形态。
            let path = decoded.hasPrefix("/") ? decoded : "/" + decoded
            out.append(WebDAVResource(path: path, isDirectory: isDir, size: size,
                                      lastModified: mtime, sizeDeclared: declared != nil))
        }
        return out
    }

    static func firstTag(_ name: String, in chunk: String) -> String? {
        guard let start = chunk.range(of: "<\(name)>") ?? chunk.range(of: "<\(name) ") else { return nil }
        guard let end = chunk.range(of: "</\(name)>", range: start.upperBound..<chunk.endIndex) else { return nil }
        return String(chunk[start.upperBound..<end.lowerBound])
    }
}

extension Data {
    /// 追加写（流式下载用；调用方保证目录已存在）。
    fileprivate func appendToFile(at url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try write(to: url, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: self)
        }
    }
}
