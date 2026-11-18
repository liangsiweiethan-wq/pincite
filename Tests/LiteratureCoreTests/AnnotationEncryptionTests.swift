import CryptoKit
import Foundation
import SQLite3
@testable import LiteratureCore

// MARK: - 批注加密集成测试（六枚）

enum AnnotationEncryptionSuite {
    /// 密闭守卫：注入手织钥（Keychain 换ACL即弹授权窗会无限阻塞测试进程，
    /// 见 AnnotationCrypto.keyProvider 说明）＋开关复位 false，任何退出路径
    /// 都恢复生产默认值，不污染后续套件。
    private static func withEncryptionOff(_ body: () throws -> Void) throws {
        let injected = SymmetricKey(size: .bits256)
        AnnotationCrypto.keyProvider = { injected }
        UserDefaults.standard.set(false, forKey: AnnotationCrypto.userDefaultsKey)
        defer {
            AnnotationCrypto.keyProvider = { try AnnotationCrypto.ensureKey() }
            UserDefaults.standard.set(false, forKey: AnnotationCrypto.userDefaultsKey)
        }
        try body()
    }

    static func makeTempStore(_ tag: String) throws -> (IndexStore, URL) {
        let dir = Fixtures.makeTempDir(tag)
        return (try Fixtures.openStore(in: dir), dir)
    }

    /// 直读 note 列原始形态（类型 + 字节），绕过 store 解码层。
    static func rawNote(_ db: SQLiteDatabase, rowid: Int64) throws -> (isBlob: Bool, bytes: Data, text: String) {
        let stmt = try db.prepare("SELECT note FROM user_highlights WHERE rowid = ?;")
        try stmt.bindInt(1, rowid)
        try expectTrue(try stmt.step(), "raw note row must exist")
        let isBlob = stmt.columnType(0) == SQLITE_BLOB
        return (isBlob, isBlob ? stmt.blob(0) : Data(), stmt.text(0))
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "AnnotationEncryption", name: "encryptDecryptRoundTrip") {
                try withEncryptionOff {
                    let key = SymmetricKey(size: .bits256)
                    let plain = "绝密批注：证据链三段论 🔒"
                    let blob = try AnnotationCrypto.encrypt(plain, key: key)
                    try expectEqual(Int(blob[0]), Int(AnnotationCrypto.currentVersion))
                    try expectTrue(blob.count > 1 + 12 + 16, "blob must exceed version+nonce+tag")
                    try expectEqual(try AnnotationCrypto.decrypt(blob, key: key), plain)
                    // 篡改一个密文字节 → GCM 认证失败必须抛错（不静默出乱码）。
                    var tampered = blob
                    tampered[blob.count - 1] ^= 0xFF
                    try expectThrows(try AnnotationCrypto.decrypt(tampered, key: key))
                }
            },

            TestDesc(suite: "AnnotationEncryption", name: "migrateExistingNotesIdempotent") {
                try withEncryptionOff {
                    let (store, dir) = try makeTempStore("annot-crypto-mig")
                    defer { Fixtures.cleanup(dir) }
                    let hs = HighlightStore(db: store.db)
                    let id1 = try hs.add(bookID: "bM", pageNumber: 1, utf16Start: 0, utf16End: 3,
                                         color: .yellow, note: "明文待迁移")
                    let _ = try hs.add(bookID: "bM", pageNumber: 2, utf16Start: 0, utf16End: 3,
                                       color: .yellow, note: "")
                    let key = SymmetricKey(size: .bits256)

                    let first = try AnnotationCrypto.migrateExistingNotes(db: store.db, key: key)
                    try expectEqual(first, 1)
                    let raw1 = try rawNote(store.db, rowid: id1)
                    try expectTrue(raw1.isBlob, "migrated note must be BLOB")
                    try expectEqual(try AnnotationCrypto.decrypt(raw1.bytes, key: key), "明文待迁移")
                    // 幂等：再跑一遍必须 0 条（BLOB 全跳过）。
                    let second = try AnnotationCrypto.migrateExistingNotes(db: store.db, key: key)
                    try expectEqual(second, 0)
                }
            },

            TestDesc(suite: "AnnotationEncryption", name: "disabledReadShowsEncryptedPlaceholder") {
                try withEncryptionOff {
                    let key = SymmetricKey(size: .bits256)
                    let blob = try AnnotationCrypto.encrypt("机密", key: key)
                    try expectEqual(
                        AnnotationCrypto.decodedNote(raw: blob, text: nil, key: key, enabled: false),
                        AnnotationCrypto.encryptedNotePlaceholder)
                    // key 为 nil 时不影响占位判定（关闭态根本不取钥）。
                    try expectEqual(
                        AnnotationCrypto.decodedNote(raw: blob, text: "legacy", key: nil, enabled: false),
                        AnnotationCrypto.encryptedNotePlaceholder)
                    // raw 空/nil → 明文回退路径原样生效。
                    try expectEqual(AnnotationCrypto.decodedNote(raw: nil, text: "旧明文", key: key, enabled: false), "旧明文")
                    try expectEqual(AnnotationCrypto.decodedNote(raw: Data(), text: nil, key: key, enabled: true), "")
                }
            },

            TestDesc(suite: "AnnotationEncryption", name: "enabledReadReturnsOriginal") {
                try withEncryptionOff {
                    let key = SymmetricKey(size: .bits256)
                    let plain = "开关开启后应见原文"
                    let blob = try AnnotationCrypto.encrypt(plain, key: key)
                    try expectEqual(
                        AnnotationCrypto.decodedNote(raw: blob, text: "应被忽略", key: key, enabled: true),
                        plain)
                }
            },

            TestDesc(suite: "AnnotationEncryption", name: "plaintextLegacyReadUnchangedWhenDisabled") {
                try withEncryptionOff {
                    let (store, dir) = try makeTempStore("annot-crypto-legacy")
                    defer { Fixtures.cleanup(dir) }
                    let hs = HighlightStore(db: store.db)
                    let id = try hs.add(bookID: "bL", pageNumber: 1, utf16Start: 0, utf16End: 2,
                                        color: .blue, note: "历史明文批注")
                    let raw = try rawNote(store.db, rowid: id)
                    try expectFalse(raw.isBlob, "disabled write must stay TEXT")
                    let listed = try hs.highlightsForBook("bL")
                    try expectEqual(listed.count, 1)
                    try expectEqual(listed.first?.note, "历史明文批注")
                }
            },

            TestDesc(suite: "AnnotationEncryption", name: "decryptFailureShowsPlaceholder") {
                try withEncryptionOff {
                    let key = SymmetricKey(size: .bits256)
                    let wrongKey = SymmetricKey(size: .bits256)
                    var tampered = try AnnotationCrypto.encrypt("正文", key: key)
                    tampered[tampered.count - 1] ^= 0xFF
                    try expectEqual(
                        AnnotationCrypto.decodedNote(raw: tampered, text: nil, key: key, enabled: true),
                        AnnotationCrypto.decryptFailedPlaceholder)
                    try expectEqual(
                        AnnotationCrypto.decodedNote(raw: try AnnotationCrypto.encrypt("正文", key: key),
                                                     text: nil, key: wrongKey, enabled: true),
                        AnnotationCrypto.decryptFailedPlaceholder)
                    // 版本字节不符（0x00）→ unsupportedVersion → 占位。
                    var badVersion = try AnnotationCrypto.encrypt("正文", key: key)
                    badVersion[0] = 0x00
                    try expectEqual(
                        AnnotationCrypto.decodedNote(raw: badVersion, text: nil, key: key, enabled: true),
                        AnnotationCrypto.decryptFailedPlaceholder)
                    // key 缺失（Keychain 不可得的容错形态）→ 占位不崩。
                    let intact = try AnnotationCrypto.encrypt("正文", key: key)
                    try expectEqual(
                        AnnotationCrypto.decodedNote(raw: intact, text: nil, key: nil, enabled: true),
                        AnnotationCrypto.decryptFailedPlaceholder)
                }
            },

            TestDesc(suite: "AnnotationEncryption", name: "storeRoundTripWithInitMigrationHook") {
                try withEncryptionOff {
                    let (store, dir) = try makeTempStore("annot-crypto-e2e")
                    defer { Fixtures.cleanup(dir) }
                    let hs = HighlightStore(db: store.db)
                    let id = try hs.add(bookID: "bE", pageNumber: 1, utf16Start: 0, utf16End: 2,
                                        color: .green, note: "端到端机密")
                    try expectEqual(try hs.highlightsForBook("bE").first?.note, "端到端机密")

                    UserDefaults.standard.set(true, forKey: AnnotationCrypto.userDefaultsKey)
                    // 重开 store：init 迁移钩应把存量明文搬进密文（幂等钩）。
                    let hs2 = HighlightStore(db: store.db)
                    let raw = try rawNote(store.db, rowid: id)
                    try expectTrue(raw.isBlob, "init hook must migrate legacy plaintext to BLOB")
                    try expectEqual(try hs2.highlightsForBook("bE").first?.note, "端到端机密")
                    // 开关关：同一密文行读出占位。
                    UserDefaults.standard.set(false, forKey: AnnotationCrypto.userDefaultsKey)
                    try expectEqual(try hs2.highlightsForBook("bE").first?.note,
                                    AnnotationCrypto.encryptedNotePlaceholder)
                    // 再开：原文复原（同钥解密）。
                    UserDefaults.standard.set(true, forKey: AnnotationCrypto.userDefaultsKey)
                    try expectEqual(try hs2.highlightsForBook("bE").first?.note, "端到端机密")
                }
            },
        ]
    }
}
