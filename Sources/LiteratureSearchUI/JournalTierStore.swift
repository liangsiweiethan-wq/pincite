import Foundation
// 本文件纯 Foundation（无 LiteratureCore 符号消费），无条件导入——iOS/watch
// 同模块直编与 macOS 静态库两形态下均零条件编译（白名单不扩展）。

// MARK: - 功能扩展 期刊等级内联徽章（用户自备数据）

/// 一条期刊等级规则（journal_tiers.json 的 tiers 数组项）。
public struct JournalTierRule: Equatable, Sendable {
    public let match: String
    public let tier: String
    public let note: String?

    public init(match: String, tier: String, note: String? = nil) {
        self.match = match
        self.tier = tier
        self.note = note
    }
}

public final class JournalTierStore {
    /// 数据文件固定名（AppSupport 根目录；与 reader-preferences.json 同位）。
    public static let fileName = "journal_tiers.json"
    /// 载荷版本（拒识非 1——schema 演进时递增并同步拒识旧档）。
    static let supportedVersion = 1

    private let fileURL: URL
    /// 规则表（load 一次进内存；查表无 I/O）。
    public private(set) var rules: [JournalTierRule] = []

    /// 生产默认：AppSupport 根目录；测试注入临时目录。
    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        load()
    }

    /// 大小写不敏感子串匹配（首条命中即返回；零数据/零命中 → nil，
    /// 调用侧不出徽章）。
    public func lookup(displayTitle: String) -> JournalTierRule? {
        guard !displayTitle.isEmpty else { return nil }
        return rules.first { rule in
            !rule.match.isEmpty && displayTitle.range(of: rule.match,
                                                      options: [.caseInsensitive]) != nil
        }
    }

    // MARK: 装载（fail-closed 空表：缺文件/坏 JSON/version 拒识/条目缺键一律空）

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.supportedVersion else { return }
        rules = payload.tiers.compactMap { entry in
            let match = entry.match.trimmingCharacters(in: .whitespacesAndNewlines)
            let tier = entry.tier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !match.isEmpty, !tier.isEmpty else { return nil }
            return JournalTierRule(match: match, tier: tier, note: entry.note)
        }
    }

    private struct Payload: Decodable {
        struct Entry: Decodable {
            let match: String
            let tier: String
            let note: String?
        }
        let version: Int
        let tiers: [Entry]
    }
}
