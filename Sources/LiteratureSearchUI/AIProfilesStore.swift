import Foundation
import Security
// macOS Xcode builds link LiteratureCore as a library; iOS/watch app targets
// compile the core sources directly into the same target (widget pattern), so
// the import exists only when the module does.（与 HitRouter.swift:5
// 同形的最小防护；条件编译白名单说明扩展本文件。）
#if canImport(LiteratureCore)
import LiteratureCore
#endif


/// 一个 AI 服务档案。不含 key（key 在 Keychain，account=id.uuidString）。
public struct AIProfile: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// 完整 endpoint URL（字符串存盘；解析与 HTTPS 校验在 resolve 时做）。
    public var baseURL: String
    /// 模型标识，用户显式填写，绝不推断。
    public var model: String
    public var note: String
    public var createdAt: Date
    /// 档案分型：nil/"cloud"＝云端 OpenAI 形状；"onDevice"＝端上档
    /// （Apple Foundation Models，数据不出设备）。可选字段走 Codable 合成
    /// decodeIfPresent：存量 ai-profiles.json 无 kind 字段解码为 nil＝云端，
    /// 行为不变；schema_version 保持 1（升位=decodeFile 严格等值门把存量
    /// 档案库 fail-closed 清空， 明令禁止）。
    public var kind: String?

    public init(id: UUID = UUID(), name: String, baseURL: String, model: String,
                note: String = "", createdAt: Date = Date(), kind: String? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.note = note
        self.createdAt = createdAt
        self.kind = kind
    }
}

/// 任务用途。每个用途绑定一个档案；未绑定回退默认档案。
public enum AIPurpose: String, Codable, CaseIterable, Identifiable {
    case translate      // 翻译（每日一句·翻译）
    case summarize      // 总结（多证据综合）
    case explain        // 解释（选中片段/对比）
    case grammar        // 语法拆解（每日一句·语法）
    case dailyQuote
    case freeChat
    case speedRead      // 四段式速读（综合通道＋预设问题模板）

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .translate: return L10n.purposeTranslate
        case .summarize: return L10n.purposeSummarize
        case .explain: return L10n.purposeExplain
        case .grammar: return L10n.purposeGrammar
        case .dailyQuote: return L10n.purposeDailyQuote
        case .freeChat: return L10n.purposeFreeChat
        case .speedRead: return L10n.purposeSpeedRead
        }
    }
}

public enum AIProfileError: Error, Equatable, CustomStringConvertible {
    /// 一个档案都没有（尚未导入/新建）。
    case noProfiles
    /// 路由指向的档案已被删除。
    case profileNotFound
    /// 档案元数据非法（URL 为空/非 HTTPS/模型为空）。
    case invalidProfile(String)
    /// fail-closed：Keychain 读取失败或没有密钥，禁止发送。
    case missingKey(profileName: String)
    /// 旧渠道导入失败（JSON 不可读或旧 Keychain 项取不到密钥）。
    case legacyImportFailed(String)
    /// 端上模型体检失败（类型化原因＋恢复指引；已阻止发送）。
    /// 与「配置解析失败（不可降级项）」划清界限：这是用户显式绑端上而
    /// 设备不可用的显式报错——预览阶段拦截，零发送；改绑云端属用户显式动作。
    case onDeviceUnavailable(OnDeviceModelStatus)

    public var description: String {
        switch self {
        case .noProfiles:
            return "未配置 AI 档案：不会发出任何请求"
        case .profileNotFound:
            return "路由指向的档案不存在"
        case .invalidProfile(let detail):
            return "档案配置无效：\(detail)"
        case .missingKey(let name):
            return "密钥缺失：档案「\(name)」未配置 API key（已阻止发送）"
        case .legacyImportFailed(let detail):
            return "现有渠道配置不可用：\(detail)"
        case .onDeviceUnavailable(let status):
            return "端上模型不可用（已阻止发送）：\(status.diagnosticText) 可改绑云端档案后重新确认发送。"
        }
    }
}

// MARK: - Keychain 抽象（可注入，测试用内存桩）

/// AIKeyStorage 收敛为 SecretStore（LiteratureCore）的细化协议——
/// 读失败以 throw 区分（调用方 fail-closed），SecretStore.read 以 nil 折叠。
public protocol AIKeyStorage: SecretStore {
    /// nil = 该项不存在；抛错 = 读取失败（调用方 fail-closed）。
    func readKey(account: String) throws -> String?
    func writeKey(_ value: String, account: String) throws
    func deleteKey(account: String) throws
}

/// SecretStore 桥接默认实现：任何 AIKeyStorage 自动满足 SecretStore。
/// read 折叠「不存在」与「读失败」为 nil——与 AIProfilesStore 调用点
/// 「两种情形同按缺密钥拦截」的既有语义一致（行为不变）。
extension AIKeyStorage {
    public func save(_ data: String, account: String) throws {
        try writeKey(data, account: account)
    }
    public func read(account: String) -> String? {
        (try? readKey(account: account)) ?? nil
    }
    public func delete(account: String) {
        try? deleteKey(account: account)
    }
}

/// Security framework 实现。service 默认 com.example.literaturesearch.ai（AI 档案）；
/// WebDAV 密码走独立 service（webdavService），避免与 AI key 混桶。
public struct SecurityFrameworkKeyStorage: AIKeyStorage {
    public static let service = "com.example.literaturesearch.ai"
    public static let webdavService = "com.example.literaturesearch.webdav"

    /// 实例级 service：默认与历史行为完全一致；WebDAV 面板注入专用 service。
    public let service: String

    public init(service: String = SecurityFrameworkKeyStorage.service) {
        self.service = service
    }

    public func readKey(account: String) throws -> String? {
        try readKey(service: service, account: account)
    }

    /// 读任意 service/account（仅用于迁移旧渠道档案，调用点显式给出）。
    public func readKey(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw AIProfileError.missingKey(profileName: "Keychain")
        }
        return value
    }

    public func writeKey(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let lookup = base.merging([
            kSecAttrAccount as String: account,
        ]) { _, new in new }
        let status = SecItemCopyMatching(lookup as CFDictionary, nil)
        if status == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: data]
            let result = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
            guard result == errSecSuccess else { throw AIProfileError.missingKey(profileName: "Keychain") }
        } else if status == errSecItemNotFound {
            let insert = base.merging([
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
            ]) { _, new in new }
            let result = SecItemAdd(insert as CFDictionary, nil)
            guard result == errSecSuccess else { throw AIProfileError.missingKey(profileName: "Keychain") }
        } else {
            throw AIProfileError.missingKey(profileName: "Keychain status \(status)")
        }
    }

    public func deleteKey(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // 不存在不算错误（幂等删除）。
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AIProfileError.missingKey(profileName: "Keychain")
        }
    }
}

/// 合成测试桩：零 Keychain 副作用。
public final class InMemoryKeyStorage: AIKeyStorage {
    public private(set) var storage: [String: String] = [:]
    public init() {}
    public func readKey(account: String) throws -> String? { storage[account] }
    public func writeKey(_ value: String, account: String) throws { storage[account] = value }
    public func deleteKey(account: String) throws { storage.removeValue(forKey: account) }
}

// MARK: - 档案存储（JSON 元数据 + UserDefaults 路由表）

public final class AIProfilesStore {
    /// 落盘格式版本；坏档/未来版本一律 fail-closed 视为空档。
    private static let schemaVersion = 1
    private static let routingKey = "aiPurposeRouting.v1"
    private static let defaultKey = "aiDefaultProfileID.v1"

    public private(set) var profiles: [AIProfile]
    public private(set) var defaultProfileID: UUID?

    private let directory: URL
    private let fileURL: URL
    private let defaults: UserDefaults
    /// 密钥读写统一经 SecretStore 协议（生产=本机钥匙串，
    /// 测试=内存桩）；对外 init 参数标签 keyStorage 保持既有调用点零改动。
    private let secrets: SecretStore
    /// 已导入旧渠道标记（JSON 内持久化；导入过的不再重复导入）。
    private var migratedLegacy: Bool

    public init(directory: URL = AIProfilesStore.defaultDirectory(),
                defaults: UserDefaults = .standard,
                keyStorage: SecretStore = SecurityFrameworkKeyStorage()) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("ai-profiles.json", isDirectory: false)
        self.defaults = defaults
        self.secrets = keyStorage
        let disk = Self.decodeFile(fileURL)
        self.profiles = disk?.profiles ?? []
        self.defaultProfileID = disk?.defaultProfileID
        self.migratedLegacy = disk?.migratedLegacy ?? false
        // 路由表只认现存档案 ID；指向已删档案的条目静默丢弃。
        let raw = defaults.dictionary(forKey: Self.routingKey) as? [String: String] ?? [:]
        var clean: [AIPurpose: UUID] = [:]
        for (key, value) in raw {
            guard let purpose = AIPurpose(rawValue: key), let id = UUID(uuidString: value),
                  profiles.contains(where: { $0.id == id }) else { continue }
            clean[purpose] = id
        }
        self.routing = clean
        if let storedDefault = defaults.string(forKey: Self.defaultKey),
           let id = UUID(uuidString: storedDefault),
           profiles.contains(where: { $0.id == id }) {
            self.defaultProfileID = id
        } else if defaultProfileID == nil, let first = profiles.first {
            // 无默认但有档案：回退首个，保证路由总有落点。
            self.defaultProfileID = first.id
        }
    }

    /// 生产默认：~/Library/Application Support/LiteratureSearch/。
    /// 根目录推导收拢至 AppSupportPaths（落点不变）。
    public static func defaultDirectory() -> URL {
        AppSupportPaths.appDirectory()
    }

    // MARK: 查询

    // 视图层只读便利（主线程补齐；不改既有公共 API 语义）
    public func isDefault(_ id: UUID) -> Bool { defaultProfileID == id }
    public func rename(_ id: UUID, name: String) {
        guard var p = profile(id: id), !name.isEmpty else { return }
        p.name = name
        upsert(p)
    }
    public func updateEndpoint(_ id: UUID, url: String) {
        guard var p = profile(id: id) else { return }
        p.baseURL = url
        upsert(p)
    }
    public func updateModel(_ id: UUID, model: String) {
        guard var p = profile(id: id) else { return }
        p.model = model
        upsert(p)
    }
    public func keyConfigured(account: String) -> Bool {
        secrets.read(account: account) != nil
    }

    /// 读档案密钥（视图预填用）。保留 throws 签名：读失败与不存在同返 nil，
    /// 调用方语义不变（缺失即空串，不外泄钥匙串错误细节）。
    public func readKeyFromStorage(account: String) throws -> String? {
        secrets.read(account: account)
    }

    public func profile(id: UUID) -> AIProfile? {
        profiles.first(where: { $0.id == id })
    }

    /// 用途绑定的档案 ID；未绑定 → 默认档案。
    public func profileID(for purpose: AIPurpose) -> UUID? {
        routing[purpose] ?? defaultProfileID
    }

    public func profile(for purpose: AIPurpose) -> AIProfile? {
        profileID(for: purpose).flatMap { profile(id: $0) }
    }

    /// 发送/预览前的唯一取配置入口。fail-closed：任何一步失败都返回
    public func resolveConfiguration(for purpose: AIPurpose) -> Result<AIConfiguration, AIProfileError> {
        guard !profiles.isEmpty else { return .failure(.noProfiles) }
        guard let id = profileID(for: purpose), let profile = profile(id: id) else {
            return .failure(.profileNotFound)
        }
        return resolveConfiguration(of: profile)
    }

    public func resolveConfiguration(of profile: AIProfile) -> Result<AIConfiguration, AIProfileError> {
        // 分型：端上档跳过 HTTPS/密钥检查——数据不出设备，无密钥
        // 可言；返回占位配置（OnDeviceEndpoint：RFC 2606 `.invalid` 保留顶级
        // 域保证不可路由。端上 transport 不使用该 URL；万一误经
        // URLSessionAITransport 发送，DNS 解析必然失败＝显式错误，数据不会
        // 出机——这条论证见 FoundationModelsTransport.swift 文件头）。
        if OnDeviceProfileKind.isOnDevice(profile.kind) {
            return .success(AIConfiguration(
                serviceURL: URL(string: OnDeviceEndpoint.placeholderURLString)!,
                model: OnDeviceEndpoint.modelIdentifier,
                apiKey: nil,
                displayName: L10n.aiProfileOnDeviceName))
        }
        let trimmed = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            return .failure(.invalidProfile("服务地址无效"))
        }
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            return .failure(.invalidProfile("服务地址必须是 HTTPS（Bearer 密钥不得走明文 HTTP）"))
        }
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return .failure(.invalidProfile("模型标识必须填写")) }
        // 经 SecretStore 读：nil（不存在/读失败）与空串同按缺密钥拦截，
        // 与改道前 fail-closed 行为一致。
        guard let key = secrets.read(account: profile.id.uuidString), !key.isEmpty else {
            return .failure(.missingKey(profileName: profile.name))
        }
        return .success(AIConfiguration(serviceURL: url, model: model, apiKey: key))
    }

    // MARK: 写入

    /// 新增或按 id 更新元数据（不触碰 Keychain；key 经 upsertKey 单独写）。
    public func upsert(_ profile: AIProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        if defaultProfileID == nil { defaultProfileID = profile.id }
        persist()
    }

    /// 写/换档案密钥。空串拒绝（fail-closed，不允许「写空密钥」抹掉守卫）。
    public func upsertKey(_ value: String, for profileID: UUID) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIProfileError.missingKey(profileName: "（空密钥）") }
        try secrets.save(trimmed, account: profileID.uuidString)
    }

    /// 删除档案：元数据 + 路由条目 + Keychain 项一起删。
    public func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        routing = routing.filter { $0.value != id }
        secrets.delete(account: id.uuidString)
        if defaultProfileID == id {
            defaultProfileID = profiles.first?.id
        }
        persist()
    }

    public func setDefault(id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        defaultProfileID = id
        persist()
    }

    /// 绑定用途 → 档案；nil = 解绑（该用途回退默认档案）。
    public func bind(_ purpose: AIPurpose, to id: UUID?) {
        if let id, profiles.contains(where: { $0.id == id }) {
            routing[purpose] = id
        } else {
            routing.removeValue(forKey: purpose)
        }
        persistRouting()
    }

    // MARK: 旧渠道迁移（一次性）

    private struct LegacyChannel: Decodable {
        let endpoint: String
        let model: String
        let keychain_service: String
        let keychain_account: String
    }

    /// 现有单档案设置（AI profile file + 其 Keychain 项）自动导入为
    /// 第一个档案。已导入过则直接返回既有档案（幂等，不重复建）。
    public func importLegacyChannel(
        legacyJSON url: URL,
        keyReader: (_ service: String, _ account: String) throws -> String?
    ) throws -> AIProfile {
        if migratedLegacy, let existing = profiles.first {
            return existing
        }
        struct LegacyBox: Decodable { let channel: LegacyChannel }
        let data: Data
        let channel: LegacyChannel
        do {
            data = try Data(contentsOf: url)
            let box = try? JSONDecoder().decode(LegacyBox.self, from: data)
            channel = try box?.channel ?? JSONDecoder().decode(LegacyChannel.self, from: data)
        } catch {
            throw AIProfileError.legacyImportFailed("渠道描述文件不可读")
        }
        guard let rawKey = try keyReader(channel.keychain_service, channel.keychain_account)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !rawKey.isEmpty else {
            throw AIProfileError.legacyImportFailed("旧 Keychain 项不存在或为空（凭证不会显示或保存到磁盘）")
        }
        let key = rawKey
        let profile = AIProfile(name: "现有渠道", baseURL: channel.endpoint, model: channel.model,
                                note: "自 AI profile file 导入")
        try secrets.save(key, account: profile.id.uuidString)
        profiles.append(profile)
        if defaultProfileID == nil { defaultProfileID = profile.id }
        migratedLegacy = true
        persist()
        return profile
    }

    // MARK: - 私有：装载与原子写

    private var routing: [AIPurpose: UUID]

    private struct DiskFile: Codable {
        var schema_version: Int
        var profiles: [AIProfile]
        var default_profile_id: UUID?
        var migrated_legacy: Bool
    }

    private static func decodeFile(_ url: URL) -> (profiles: [AIProfile],
                                                   defaultProfileID: UUID?,
                                                   migratedLegacy: Bool)? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(DiskFile.self, from: data),
              file.schema_version == Self.schemaVersion else { return nil }
        return (file.profiles, file.default_profile_id, file.migrated_legacy)
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = DiskFile(schema_version: Self.schemaVersion,
                                profiles: profiles,
                                default_profile_id: defaultProfileID,
                                migrated_legacy: migratedLegacy)
            try JSONEncoder().encode(file).write(to: fileURL, options: .atomic)
        } catch {
            fputs("AIProfilesStore: 持久化失败 \(error)\n", stderr)
        }
        persistRouting()
    }

    private func persistRouting() {
        let raw = Dictionary(uniqueKeysWithValues: routing.map { ($0.key.rawValue, $0.value.uuidString) })
        defaults.set(raw, forKey: Self.routingKey)
        defaults.set(defaultProfileID?.uuidString, forKey: Self.defaultKey)
    }
}

// MARK: - 连通测试（用户显式点击；不经 AI 确认门，零自动发送承诺不变）

public struct AIProfilePingRawResponse: Equatable {
    public var statusCode: Int
    public var body: String
    public init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = body
    }
}

public struct AIProfilePingResult: Equatable {
    public var ok: Bool
    public var statusCode: Int
    public var latencyMs: Int
    /// 成功时模型回显（choices[0].message.content 截断）。
    public var echo: String
    /// 失败时错误体前 200 字。
    public var errorSnippet: String
    /// 网络层错误描述（DNS/超时/TLS 等），与 HTTP 错误互斥。
    public var transportError: String?
}

public protocol AIProfilePingTransport {
    /// 非 2xx 也返回原始响应（不抛错），由调用方组装失败结果；
    /// 仅传输层失败才 throw。
    func ping(endpoint: URL, model: String, apiKey: String?) async throws -> AIProfilePingRawResponse
}

/// 生产实现：OpenAI chat/completions 一条短问，ephemeral session，HTTPS。
public struct URLSessionAIProfilePingTransport: AIProfilePingTransport {
    private struct Message: Encodable { var role: String; var content: String }
    private struct Body: Encodable {
        var model: String
        var messages: [Message]
        var max_tokens: Int
        var stream: Bool
    }

    public init() {}

    public func ping(endpoint: URL, model: String, apiKey: String?) async throws -> AIProfilePingRawResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body = Body(model: model,
                        messages: [Message(role: "user", content: "请回复：连通正常")],
                        max_tokens: 16, stream: false)
        request.httpBody = try JSONEncoder().encode(body)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return AIProfilePingRawResponse(statusCode: status,
                                        body: String(data: data, encoding: .utf8) ?? "")
    }
}

public struct AIProfileConnectionTester {
    public let transport: AIProfilePingTransport
    public let keyStorage: AIKeyStorage

    public init(transport: AIProfilePingTransport = URLSessionAIProfilePingTransport(),
                keyStorage: AIKeyStorage = SecurityFrameworkKeyStorage()) {
        self.transport = transport
        self.keyStorage = keyStorage
    }

    /// 发一条真实短问（调用点=用户显式点击「测试」）。密钥缺失 fail-closed，
    /// 不发出请求。
    public func test(_ profile: AIProfile) async -> AIProfilePingResult {
        let base = AIProfilePingResult(ok: false, statusCode: 0, latencyMs: 0,
                                       echo: "", errorSnippet: "", transportError: nil)
        guard let url = URL(string: profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil else {
            return AIProfilePingResult(ok: false, statusCode: 0, latencyMs: 0, echo: "",
                                       errorSnippet: L10n.aiProfileInvalidURLError, transportError: nil)
        }
        let key: String?
        do {
            key = try keyStorage.readKey(account: profile.id.uuidString)
        } catch {
            key = nil
        }
        guard let key, !key.isEmpty else {
            return AIProfilePingResult(ok: false, statusCode: 0, latencyMs: 0, echo: "",
                                       errorSnippet: L10n.aiProfileKeyMissingError, transportError: nil)
        }
        let start = Date()
        let raw: AIProfilePingRawResponse
        do {
            raw = try await transport.ping(endpoint: url, model: profile.model, apiKey: key)
        } catch {
            return AIProfilePingResult(ok: false, statusCode: 0,
                                       latencyMs: Int(start.timeIntervalSinceNow * -1000),
                                       echo: "", errorSnippet: "",
                                       transportError: String(describing: error))
        }
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        guard (200..<300).contains(raw.statusCode) else {
            return AIProfilePingResult(ok: false, statusCode: raw.statusCode, latencyMs: latency,
                                       echo: "", errorSnippet: String(raw.body.prefix(200)),
                                       transportError: nil)
        }
        let echo = Self.extractEcho(from: raw.body)
        return AIProfilePingResult(ok: echo != nil, statusCode: raw.statusCode, latencyMs: latency,
                                   echo: echo ?? "", errorSnippet: echo == nil ? String(raw.body.prefix(200)) : "",
                                   transportError: nil)
    }

    /// choices[0].message.content（容错解析；失败返回 nil 让上层按失败展示）。
    static func extractEcho(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let content = choices.first?["message"] as? [String: Any],
              let text = content["content"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }
}

// MARK: - 密钥文件状态卡（只读：存在性 + 权限；不读内容、不上传）

public struct APIKeyFileStatus: Equatable {
    public var path: String
    public var exists: Bool
    /// 三位八进制（如 "600"）；文件不存在为 nil。
    public var permissionsOctal: String?
    public var is600: Bool
}

public enum APIKeyFileInspector {
    public static let defaultPath = "~/.config/literaturesearch/keys/api.key"

    /// 只查 FileManager 属性（posixPermissions），绝不读文件内容。
    public static func check(path: String = APIKeyFileInspector.defaultPath) -> APIKeyFileStatus {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let perms = attrs[.posixPermissions] as? Int else {
            return APIKeyFileStatus(path: expanded, exists: false, permissionsOctal: nil, is600: false)
        }
        let octal = String(format: "%03o", perms & 0o777)
        return APIKeyFileStatus(path: expanded, exists: true, permissionsOctal: octal,
                            is600: (perms & 0o777) == 0o600)
    }
}
