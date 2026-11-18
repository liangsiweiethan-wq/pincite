import Foundation

// MARK: - 键位 JSON 外置：注册表（镜：Sioyek 双层文件 + Sumatra

/// 一条键位条目（默认表与用户覆盖同构；用户文件条目的 enabled 缺省 true）。
public struct KeybindingEntry: Codable, Equatable, Sendable {
    public var action: String
    public var key: String
    /// 修饰键，规范序：control option shift command。
    public var modifiers: [String]
    /// 原始输入含未知修饰键名（normalize 静默滤掉的；重复键名同计入）。
    /// isWellFormed 据此拒绝——防「拼错修饰键在放宽后静默降级成裸键」的
    /// 脚枪（护栏；键名 junk 在 decode 期就被归一，事后比对拿不到）。
    public private(set) var hasUnknownModifiers: Bool
    /// false = 显式禁绑（该 action 不再占用键盘）。
    public var enabled: Bool
    /// 所属域："app"（菜单命令）/ "reader"（阅读器内）。
    public var context: String

    public init(action: String, key: String, modifiers: [String],
                enabled: Bool = true, context: String) {
        let normalized = Self.normalize(modifiers)
        self.action = action
        self.key = key
        self.modifiers = normalized
        self.hasUnknownModifiers = normalized.count != modifiers.count
        self.enabled = enabled
        self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case action, key, modifiers, enabled, context
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        key = try c.decode(String.self, forKey: .key)
        let rawModifiers = try c.decode([String].self, forKey: .modifiers)
        modifiers = Self.normalize(rawModifiers)
        hasUnknownModifiers = modifiers.count != rawModifiers.count
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        context = try c.decode(String.self, forKey: .context)
    }

    /// 修饰键规范化（未知键名剔除、大小写归一、固定排序——⌘⌥⇧⌃ 展示序）。
    static func normalize(_ modifiers: [String]) -> [String] {
        let order = ["command", "option", "shift", "control"]
        let known = modifiers.map { $0.lowercased() }.filter { order.contains($0) }
        return order.filter { known.contains($0) }
    }

    /// 条目是否可解析（坏字段条目被拒并告警）。
    ///
    /// 阅读器批放宽：modifiers 允许为**空**（裸键）。阅读器 marks（`m`/
    /// `'`）与 f 键候选角标（`f`）是 vim/Zathura 式裸键语义，带修饰键反而
    /// 反直觉；此前 `!modifiers.isEmpty` 使裸键条目永远过不了 well-formed。
    /// 放宽只影响**新条目的接受度**——默认表既有 16 项全带修饰键，行为零
    /// 变化；默认表前 16 项与 字面量逐项一致由 KeybindingTests 锁定。
    /// 未知修饰键名仍然拒绝（junk 在 decode 期被 normalize 静默滤空，事后
    /// 比对拿不到——由 hasUnknownModifiers 旗标在入口捕获；防「拼错修饰键
    /// 静默降级成裸键」，KeybindingTests bogus 行为不变）。
    public var isWellFormed: Bool {
        key.count == 1 && !action.isEmpty && !context.isEmpty
            && !hasUnknownModifiers
    }
}

/// 合并后的生效键（含来源与启用态——禁绑条目保留于诊断列表，红标显示）。
public struct KeybindingSpec: Equatable, Hashable, Sendable {
    public enum Source: String, Sendable { case builtin, user }

    public let action: String
    public let key: String
    public let modifiers: [String]
    public let context: String
    public let enabled: Bool
    public let source: Source
}

/// 同 (context, key, modifiers) 多 action 冲突（红标显示，不问题）。
public struct KeybindingConflict: Equatable, Sendable {
    public let context: String
    public let key: String
    public let modifiers: [String]
    public let actions: [String]
}

// MARK: - 注册表

public struct KeybindingRegistry: Sendable {
    /// 合并后全量条目（默认 + 覆盖，默认表顺序为骨架）。
    public let specs: [KeybindingSpec]
    /// 解析告警（坏 JSON 回退 / 坏字段 / 未知 action / 冲突；设置页可见）。
    public let warnings: [String]
    /// 用户文件不可读/坏 JSON → fail-closed 回默认表时置位。
    public let usedFallback: Bool

    public static let defaultEntries: [KeybindingEntry] = [
        // app 域 11 项（LiteratureSearchAppMain.swift 命令菜单）
        KeybindingEntry(action: "openFolder", key: "o", modifiers: ["command"], context: "app"),
        KeybindingEntry(action: "navSearch", key: "1", modifiers: ["command", "shift"], context: "app"),
        KeybindingEntry(action: "navHistory", key: "2", modifiers: ["command", "shift"], context: "app"),
        KeybindingEntry(action: "navCoverage", key: "3", modifiers: ["command", "shift"], context: "app"),
        KeybindingEntry(action: "navLibrary", key: "4", modifiers: ["command", "shift"], context: "app"),
        KeybindingEntry(action: "navQuote", key: "5", modifiers: ["command", "shift"], context: "app"),
        KeybindingEntry(action: "columnSidebar", key: "1", modifiers: ["command"], context: "app"),
        KeybindingEntry(action: "columnResults", key: "2", modifiers: ["command"], context: "app"),
        KeybindingEntry(action: "columnDetail", key: "3", modifiers: ["command"], context: "app"),
        KeybindingEntry(action: "focusSearch", key: "f", modifiers: ["command"], context: "app"),
        KeybindingEntry(action: "commandPalette", key: "k", modifiers: ["command"], context: "app"),
        // reader 域 5 项（ReadingChrome.swift）
        KeybindingEntry(action: "historyBack", key: "[", modifiers: ["command"], context: "reader"),
        KeybindingEntry(action: "historyForward", key: "]", modifiers: ["command"], context: "reader"),
        // overview 与 openFolder 同键不同 context：注册表按 context 分域求值，
        // 现状语义保持（⌘O 在阅读器内是概览弹窗）。
        KeybindingEntry(action: "overview", key: "o", modifiers: ["command"], context: "reader"),
        KeybindingEntry(action: "docSearchPrev", key: "g", modifiers: ["command", "shift"], context: "reader"),
        KeybindingEntry(action: "docSearchNext", key: "g", modifiers: ["command"], context: "reader"),
        // 阅读器批追加（reader 域三条裸键，表尾追加不动前 16 项）
        // 单字符 Marks（设标 m / 跳回 '）与 f 键引文候选角标。实际键入在
        // QuotePDFView.keyDown（全仓唯一新增键盘事件入口）内直配
        // 同名裸键；注册表条目先例照 ReadingChrome registeredShortcut——
        // 供设置页诊断/冲突检测/未来重绑取值，键面语义单一来源。
        KeybindingEntry(action: "marksSet", key: "m", modifiers: [], context: "reader"),
        KeybindingEntry(action: "marksJump", key: "'", modifiers: [], context: "reader"),
        KeybindingEntry(action: "followCitations", key: "f", modifiers: [], context: "reader"),
    ]

    /// 用户覆盖文件在应用支持目录的落点（与 reader-preferences.json 同目录）。
    public static func defaultUserURL() -> URL {
        AppSupportPaths.appDirectory().appendingPathComponent("keybindings.json",
                                                              isDirectory: false)
    }

    /// 内置注册表（无用户覆盖）。
    public static func builtin() -> KeybindingRegistry {
        KeybindingRegistry(
            specs: defaultEntries.map { spec(entry: $0, source: .builtin) },
            warnings: [], usedFallback: false)
    }

    /// 启动加载：读用户覆盖文件（文件不存在 = 未定制，用默认表）。
    /// 文件存在但不可读/坏 JSON → fail-closed 回默认表 + 告警标志。
    public static func load(userURL: URL?) -> KeybindingRegistry {
        guard let userURL, FileManager.default.fileExists(atPath: userURL.path) else {
            return builtin()
        }
        guard let data = try? Data(contentsOf: userURL) else {
            return fallback(warning: "keybindings.json 不可读取，已回退默认键位（fail-closed）")
        }
        return load(data: data)
    }

    /// 纯数据加载（测试注入桩文本；文件加载是它的薄封装）。
    public static func load(data: Data) -> KeybindingRegistry {
        guard let userEntries = try? JSONDecoder().decode([KeybindingEntry].self, from: data) else {
            return fallback(warning: "keybindings.json 不是合法的键位覆盖表，已回退默认键位（fail-closed）")
        }
        return merge(defaults: defaultEntries, user: userEntries)
    }

    static func fallback(warning: String) -> KeybindingRegistry {
        KeybindingRegistry(specs: defaultEntries.map { spec(entry: $0, source: .builtin) },
                           warnings: [warning], usedFallback: true)
    }

    static func spec(entry: KeybindingEntry, source: KeybindingSpec.Source) -> KeybindingSpec {
        KeybindingSpec(action: entry.action, key: entry.key, modifiers: entry.modifiers,
                       context: entry.context, enabled: entry.enabled, source: source)
    }

    /// 合并求值：默认在前、用户在后、同 (context, action) 后者胜；未知
    /// action / 坏字段条目拒收并告警（不静默）。
    public static func merge(defaults: [KeybindingEntry],
                             user: [KeybindingEntry]) -> KeybindingRegistry {
        var warnings: [String] = []
        let knownActions = Set(defaults.map(\.action))
        // 有序合并：默认表顺序为骨架，覆盖条目原位替换（差异条目模型）。
        var merged: [KeybindingEntry] = defaults
        var index: [String: Int] = [:]   // "context|action" → merged 下标
        for (i, entry) in merged.enumerated() { index["\(entry.context)|\(entry.action)"] = i }
        for entry in user {
            guard entry.isWellFormed else {
                // 放宽后拒绝面只剩：key 非单字符 / action、context 为空
                // （裸键 modifiers=[] 已合法，告警文案与规则同步，不误导）。
                warnings.append("键位条目字段不完整（action=\(entry.action)，key 需单字符），已忽略")
                continue
            }
            guard knownActions.contains(entry.action) else {
                warnings.append("未知 action：\(entry.action)（支持集合见设置页键位诊断），已忽略")
                continue
            }
            let k = "\(entry.context)|\(entry.action)"
            if let i = index[k] {
                merged[i] = entry
            } else {
                // 已知 action 但 context 与默认表不符：仍按 (context, action)
                // 追加为独立槽位（为将来视图级键位留位），冲突检测降级处理。
                index[k] = merged.count
                merged.append(entry)
            }
        }
        var overridden: Set<String> = []
        for entry in user where knownActions.contains(entry.action) && entry.isWellFormed {
            overridden.insert("\(entry.context)|\(entry.action)")
        }
        let specs = merged.map { entry in
            spec(entry: entry,
                 source: overridden.contains("\(entry.context)|\(entry.action)") ? .user : .builtin)
        }
        var allWarnings = warnings
        let provisional = KeybindingRegistry(specs: specs, warnings: allWarnings, usedFallback: false)
        let conflicts = provisional.conflicts()
        if !conflicts.isEmpty {
            let text = conflicts.map {
                "\($0.context) 域 \(combinedKey($0.key, $0.modifiers)) → \($0.actions.joined(separator: " / "))"
            }.joined(separator: "；")
            allWarnings.append("键位冲突：\(text)")
        }
        return KeybindingRegistry(specs: specs, warnings: allWarnings, usedFallback: false)
    }

    static func combinedKey(_ key: String, _ modifiers: [String]) -> String {
        modifiers.map { $0.capitalized + "+" }.joined() + key.uppercased()
    }

    /// 查询生效键：启用中的 (context, action)；禁绑条目返回 nil。
    public func shortcut(for action: String, context: String) -> KeybindingSpec? {
        specs.first { $0.action == action && $0.context == context && $0.enabled }
    }

    /// 冲突检测：合并后同 (context, key, modifiers) 对应多个启用 action。
    public func conflicts() -> [KeybindingConflict] {
        struct Slot: Hashable {
            let context: String
            let key: String
            let modifiers: [String]
        }
        var buckets: [Slot: [String]] = [:]
        for spec in specs where spec.enabled {
            let slot = Slot(context: spec.context, key: spec.key.lowercased(),
                            modifiers: spec.modifiers)
            buckets[slot, default: []].append(spec.action)
        }
        return buckets.compactMap { slot, actions in
            actions.count > 1
                ? KeybindingConflict(context: slot.context, key: slot.key,
                                     modifiers: slot.modifiers, actions: actions.sorted())
                : nil
        }
        .sorted { "\($0.context)\($0.key)\($0.actions)" < "\($1.context)\($1.key)\($1.actions)" }
    }
}
