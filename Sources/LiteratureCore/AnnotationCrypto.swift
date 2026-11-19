// 批注静态加密服务。
// 加密默认关闭；开启后新数据加密并迁移旧数据。密钥存储于 Keychain。
// （kSecClassGenericPassword，ThisDeviceOnly 语义）；密文=版本字节+GCM combined。


import CryptoKit
import Foundation
import Security
import SQLite3

public enum AnnotationCrypto {

    enum CryptoError: Error {
        /// 第二参=人读原因串。duplicate 后重读的任何异常（含
        /// invalidKeyLength、非 CryptoError 类型）统一转抛本判型，原始
        /// OSStatus/原因全文保留在 reason 里，绝不透传异型错误。
        case keychainRead(OSStatus, String)
        case keychainWrite(OSStatus)
        case keychainDelete(OSStatus)
        case invalidKeyLength(Int)
        case unsupportedVersion(UInt8)
        case truncatedBlob
        case utf8
    }

    // MARK: - 常量
    private static let service = "com.example.literaturesearch.annotation"
    private static let account = "annotation-aes256-key"
    static let currentVersion: UInt8 = 0x01
    private static let versionByteCount = 1

    /// 返回 Keychain 中的 256 位对称密钥；首次调用时生成并写入。
    ///
    /// 并发语义（修复）：并发双首启撞 errSecDuplicateItem
    /// 时，本线程临时钥一律作废，以 Keychain 既有钥重读结果为准；重读失败
    /// （项又被删/读错/长度不符）抛 keychainRead，绝不返回临时钥——否则两
    /// 进程各持不同密钥，互不能解对方密文（fail-closed）。
    static func ensureKey() throws -> SymmetricKey {
        if let existing = try keychainLoadKey() {
            return existing
        }
        // 生成 256 位随机密钥
        let key = SymmetricKey(size: .bits256)
        switch try keychainStoreKey(key) {
        case errSecSuccess:
            return key
        case errSecDuplicateItem:
            // 并发首启：另一写入者抢先落钥。临时钥作废，既有钥为准。
            // 重读的任何 thrown error（含 invalidKeyLength、
            // 非 CryptoError 类型）统一转 keychainRead——原始 OSStatus/原因
            // 进 reason；重读返回 nil 仍按 errSecItemNotFound fail-closed。
            do {
                guard let winner = try keychainLoadKey() else {
                    throw CryptoError.keychainRead(errSecItemNotFound, "duplicate 后重读返回 nil")
                }
                return winner
            } catch let e as CryptoError {
                if case .keychainRead(let status, let reason) = e {
                    throw CryptoError.keychainRead(status, reason)
                } else {
                    throw CryptoError.keychainRead(errSecDecode, "duplicate 后重读失败: \(String(describing: e))")
                }
            } catch {
                throw CryptoError.keychainRead(errSecDecode, "duplicate 后重读失败: \(String(describing: error))")
            }
        case let status:
            throw CryptoError.keychainWrite(status)
        }
    }

    // MARK: - 测试注入点（密闭化说明，先例=keyProvider）
    /// 两钩子的生产默认值快照（测试 defer 复位专用——私有 Keychain 实现
    /// 不外泄到测试代码，测试经此常量复位）。
    static let productionKeychainLoad: () throws -> SymmetricKey? = { try AnnotationCrypto.loadKey() }
    static let productionKeychainStore: (SymmetricKey) throws -> OSStatus = { AnnotationCrypto.storeKey($0) }
    /// 生产默认直连真 Keychain（loadKey / SecItemAdd 原始状态码）；测试注入
    /// 模拟 errSecDuplicateItem 并发竞态，测试零 Keychain 依赖——Keychain 项
    /// ACL 绑创建时二进制签名，跨签名读取触发 securityd 授权弹窗并无限阻塞
    /// 测试进程说明，见 keyProvider 说明）。注入后必须
    /// defer 复位生产默认值。
    static var keychainLoadKey: () throws -> SymmetricKey? = productionKeychainLoad
    static var keychainStoreKey: (SymmetricKey) throws -> OSStatus = productionKeychainStore

    static func encrypt(_ plain: String, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(Data(plain.utf8), using: key)
        guard let combined = sealed.combined else {
            // combined 表示法对 GCM 必然存在，防御性降级处理
            throw CryptoError.truncatedBlob
        }
        var blob = Data([currentVersion])
        blob.append(combined)
        return blob
    }

    static func decrypt(_ data: Data, key: SymmetricKey) throws -> String {
        guard data.count > versionByteCount else { throw CryptoError.truncatedBlob }
        let version = data[0]
        guard version == currentVersion else { throw CryptoError.unsupportedVersion(version) }
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(versionByteCount))
        let plain = try AES.GCM.open(box, using: key)
        guard let string = String(data: plain, encoding: .utf8) else { throw CryptoError.utf8 }
        return string
    }

    /// 便捷：加密并仅以密文 BLOB 形式返回（供 INSERT BLOB 列）
    static func encryptField(_ plain: String) throws -> Data {
        try encrypt(plain, key: ensureKey())
    }

    /// 便捷：从 BLOB 解密回明文
    static func decryptField(_ blob: Data) throws -> String {
        try decrypt(blob, key: ensureKey())
    }

    static func migrateRow(plain: String, key: SymmetricKey) throws -> Data {
        try encrypt(plain, key: key)
    }

    // MARK: - Keychain（kSecClassGenericPassword，同库既有风格）

    /// 查询是否已有密钥
    private static func loadKey() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw CryptoError.keychainRead(status, "Keychain 项非 Data 类型")
            }
            guard data.count == 32 else { throw CryptoError.invalidKeyLength(data.count) }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw CryptoError.keychainRead(status, "SecItemCopyMatching failed: \(status)")
        }
    }

    /// 执行写入并返回 SecItemAdd 原始状态码；成功/duplicate/失败判定上移
    /// ensureKey（修复：duplicate 不再被当成功吞掉）。
    /// 写入的密钥仅设备解锁后可读，不随备份/迁移外泄。
    private static func storeKey(_ key: SymmetricKey) -> OSStatus {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    /// 仅在换钥/擦除流程中使用：删除后旧密文不可恢复
    static func deleteKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CryptoError.keychainDelete(status)
        }
    }
}

// MARK: - 批注加密：开关 / 存量迁移 / 读取解码 / 写入基准
//
// 存储约定：user_highlights.note 列（DDL 声明 TEXT，SQLite 动态类型）——
//   明文 = TEXT（既有行为零变化）；密文 = BLOB（0x01 版本字节 + GCM combined）。
// 空串恒存明文（与迁移基准一致：空值无加密价值，读侧少一层占位分支）。
// 开关关闭时读密文 → 「［已加密批注］」占位；解密失败 → 「［批注解密失败］」
// 占位——两者都可见、可分辨，绝不静默吞掉密文或崩在读路径。
extension AnnotationCrypto {

    /// UserDefaults 开关键名（LibrarySettingsView 的 @AppStorage 同源引用）。
    public static let userDefaultsKey = "annotationEncryptionEnabled"
    static func isEncryptionEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    /// 读路径占位常量（核心层持有：L10n 表禁反向依赖 LiteratureCore）。
    static let encryptedNotePlaceholder = "［已加密批注］"
    static let decryptFailedPlaceholder = "［批注解密失败］"

    /// 取钥入口（密闭化说明）：生产路径 = Keychain ensureKey；测试注入
    /// 手织 SymmetricKey——二进制每次重编签名即变，登录钥匙串 ACL 会触发
    /// securityd 授权弹窗并无限阻塞测试进程；因此测试套件不依赖
    /// Keychain，经此钩换钥。生产默认值即 ensureKey，行为不变。
    static var keyProvider: () throws -> SymmetricKey = { try AnnotationCrypto.ensureKey() }

    static func migrateExistingNotes(db: SQLiteDatabase, key: SymmetricKey) throws -> Int {
        try db.exec("BEGIN IMMEDIATE;")
        do {
            let select = try db.prepare("SELECT rowid, note FROM user_highlights;")
            var pending: [(rowid: Int64, plain: String)] = []
            while try select.step() {
                let rowid = select.int(0)
                guard select.columnType(1) == SQLITE_TEXT else { continue } // BLOB/NULL 跳过
                let note = select.text(1)
                guard !note.isEmpty else { continue } // 空串无加密价值
                pending.append((rowid, note))
            }
            let update = try db.prepare("UPDATE user_highlights SET note = ? WHERE rowid = ?;")
            for row in pending {
                update.reset()
                try update.bindBlob(1, try encrypt(row.plain, key: key))
                try update.bindInt(2, row.rowid)
                try update.run()
            }
            try db.exec("COMMIT;")
            return pending.count
        } catch {
            db.tryExec("ROLLBACK;")
            throw error
        }
    }

    static func decodedNote(raw: Data?, text: String?, key: SymmetricKey?, enabled: Bool) -> String {
        guard let raw, !raw.isEmpty else { return text ?? "" }
        guard enabled else { return encryptedNotePlaceholder }
        guard let key else { return decryptFailedPlaceholder }
        do {
            return try decrypt(raw, key: key)
        } catch {
            return decryptFailedPlaceholder
        }
    }

    // MARK: 写入基准（全部 note 写点的共用绑定值）

    /// note 列的落库形态。加密开 → 密文 BLOB（fail-closed：Keychain 取钥或
    /// 加密失败即抛错，绝不静默降级回明文——那会让开关承诺失效）；关 → 明文。
    enum NoteStorageValue {
        case text(String)
        case blob(Data)
    }

    /// 写前归一：开关开且 note 非空 → 尝试加密；开关关或空串 → 明文。
    static func storageValue(forNote note: String) throws -> NoteStorageValue {
        guard isEncryptionEnabled(), !note.isEmpty else { return .text(note) }
        return .blob(try encrypt(note, key: try keyProvider()))
    }

    /// 把归一后的值绑到语句指定参数位（TEXT → bindText / BLOB → bindBlob）。
    static func bind(_ value: NoteStorageValue, to stmt: SQLiteDatabase.Statement, _ index: Int32) throws {
        switch value {
        case .text(let s): try stmt.bindText(index, s)
        case .blob(let d): try stmt.bindBlob(index, d)
        }
    }
}
