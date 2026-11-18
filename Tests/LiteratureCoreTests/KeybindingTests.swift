import Foundation
@testable import LiteratureCore

// MARK: - 键位注册表套件（纯 Foundation 合同测试；临时目录注入，
// 绝不触真实 AppSupport）

enum KeybindingSuite {
    static let expected: [(context: String, action: String, key: String, modifiers: [String])] = [
        ("app", "openFolder", "o", ["command"]),
        ("app", "navSearch", "1", ["command", "shift"]),
        ("app", "navHistory", "2", ["command", "shift"]),
        ("app", "navCoverage", "3", ["command", "shift"]),
        ("app", "navLibrary", "4", ["command", "shift"]),
        ("app", "navQuote", "5", ["command", "shift"]),
        ("app", "columnSidebar", "1", ["command"]),
        ("app", "columnResults", "2", ["command"]),
        ("app", "columnDetail", "3", ["command"]),
        ("app", "focusSearch", "f", ["command"]),
        ("app", "commandPalette", "k", ["command"]),
        ("reader", "historyBack", "[", ["command"]),
        ("reader", "historyForward", "]", ["command"]),
        ("reader", "overview", "o", ["command"]),
        ("reader", "docSearchPrev", "g", ["command", "shift"]),
        ("reader", "docSearchNext", "g", ["command"]),
        ("reader", "marksSet", "m", []),
        ("reader", "marksJump", "'", []),
        ("reader", "followCitations", "f", []),
    ]

    static func entryJSON(_ action: String, key: String, modifiers: [String],
                          enabled: Bool = true, context: String) -> String {
        let mods = modifiers.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"action":"\#(action)","key":"\#(key)","modifiers":[\#(mods)],"enabled":\#(enabled),"context":"\#(context)"}"#
    }

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "Keybinding", name: "defaultTableMatchesTaskSheetItemByItem") {
                let registry = KeybindingRegistry.builtin()
                try expectEqual(registry.specs.count, 19, "16 defaults + 3 reader bare keys")
                try expectTrue(registry.warnings.isEmpty)
                try expectFalse(registry.usedFallback)
                for (i, want) in expected.enumerated() {
                    let spec = registry.specs[i]
                    try expectEqual(spec.context, want.context, "row \(i) context")
                    try expectEqual(spec.action, want.action, "row \(i) action")
                    try expectEqual(spec.key, want.key, "row \(i) key")
                    try expectEqual(spec.modifiers, want.modifiers, "row \(i) modifiers")
                    try expectTrue(spec.enabled, "row \(i) enabled")
                    try expectEqual(spec.source, .builtin)
                }
                // 同键不同域共存（openFolder ⌘O / overview ⌘O）。
                try expectNotNil(registry.shortcut(for: "openFolder", context: "app"))
                try expectNotNil(registry.shortcut(for: "overview", context: "reader"))
            },

            TestDesc(suite: "Keybinding", name: "parseAcceptsWellFormedAndRejectsBadRows") {
                let data = Data("""
                [\(entryJSON("openFolder", key: "p", modifiers: ["control", "command"], context: "app")),
                 {"action":"mysteryAction","key":"x","modifiers":["command"],"context":"app"},
                 {"action":"openFolder","key":"","modifiers":["command"],"context":"app"},
                 {"action":"openFolder","key":"z","modifiers":["bogus"],"context":"app"}]
                """.utf8)
                let registry = KeybindingRegistry.load(data: data)
                // 合法条目生效（修饰键规范化为固定序：⌘⌥⇧⌃）。
                let spec = registry.shortcut(for: "openFolder", context: "app")
                try expectEqual(spec?.key, "p")
                try expectEqual(spec?.modifiers, ["command", "control"])
                try expectEqual(spec?.source, .user)
                // 未知 action → 告警不静默；缺 key / 坏 modifiers → 拒收告警。
                try expectEqual(registry.warnings.count, 3,
                                "unknown action + empty key + bogus modifiers all warn")
                try expectTrue(registry.warnings.contains { $0.contains("未知 action") })
            },

            TestDesc(suite: "Keybinding", name: "mergeLaterUserEntryWins") {
                let data = Data("""
                [\(entryJSON("focusSearch", key: "l", modifiers: ["command"], context: "app"))]
                """.utf8)
                let registry = KeybindingRegistry.load(data: data)
                let spec = try expectNotNil(registry.shortcut(for: "focusSearch", context: "app"))
                try expectEqual(spec.key, "l", "user entry overrides default (later wins)")
                try expectEqual(spec.source, .user)
                // 其余 18 项仍为内置。
                try expectEqual(registry.specs.count, 19)
                try expectEqual(registry.specs.first { $0.action == "openFolder" }?.source, .builtin)
            },

            TestDesc(suite: "Keybinding", name: "enabledFalseUnbindsAction") {
                let data = Data("""
                [\(entryJSON("commandPalette", key: "k", modifiers: ["command"], enabled: false, context: "app"))]
                """.utf8)
                let registry = KeybindingRegistry.load(data: data)
                try expectNil(registry.shortcut(for: "commandPalette", context: "app"),
                              "enabled=false is the CmdNone equivalent (explicit unbind)")
                // 禁绑条目仍出现在诊断列表（红标由 UI 层做）。
                let spec = registry.specs.first { $0.action == "commandPalette" }
                try expectEqual(spec?.enabled, false)
            },

            TestDesc(suite: "Keybinding", name: "badJSONFailsClosedToDefaults") {
                let registry = KeybindingRegistry.load(data: Data("not json at all".utf8))
                try expectTrue(registry.usedFallback, "bad JSON must set the fallback flag")
                try expectEqual(registry.specs.count, 19, "fail-closed to the default table")
                try expectEqual(registry.specs.map(\.action), KeybindingRegistry.defaultEntries.map(\.action))
                try expectTrue(registry.warnings.contains { $0.contains("fail-closed") })
                // 文件不存在 = 未定制：内置表、零告警。
                let fresh = KeybindingRegistry.load(userURL: nil)
                try expectFalse(fresh.usedFallback)
                try expectTrue(fresh.warnings.isEmpty)
            },

            TestDesc(suite: "Keybinding", name: "conflictDetectionSameKeySameDomain") {
                // 两 action 绑同键同域 → 冲突清单（不问题，不抛）。
                let data = Data("""
                [\(entryJSON("focusSearch", key: "k", modifiers: ["command"], context: "app"))]
                """.utf8)
                let registry = KeybindingRegistry.load(data: data)
                let conflicts = registry.conflicts()
                try expectEqual(conflicts.count, 1)
                let conflict = try expectNotNil(conflicts.first)
                try expectEqual(conflict.context, "app")
                try expectEqual(conflict.key, "k")
                try expectEqual(conflict.actions, ["commandPalette", "focusSearch"])
                try expectTrue(registry.warnings.contains { $0.contains("键位冲突") },
                               "conflicts surface as a warning (never silent)")
                // 默认表无冲突（reader 域 ⌘O 与 app 域 ⌘O 分域不计冲突）。
                try expectTrue(KeybindingRegistry.builtin().conflicts().isEmpty)
            },

            TestDesc(suite: "Keybinding", name: "fileRoundtripInTemporaryDirectory") {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lit-keyb-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let url = dir.appendingPathComponent("keybindings.json")
                // roundtrip：编码 → 落盘（临时目录，绝不触真实 AppSupport）→ 读回。
                let entries = [KeybindingEntry(action: "navQuote", key: "9",
                                               modifiers: ["command", "shift"], context: "app")]
                try JSONEncoder().encode(entries).write(to: url)
                let registry = KeybindingRegistry.load(userURL: url)
                let spec = try expectNotNil(registry.shortcut(for: "navQuote", context: "app"))
                try expectEqual(spec.key, "9")
                try expectEqual(spec.modifiers, ["command", "shift"])
                try expectEqual(spec.source, .user)
                try expectFalse(registry.usedFallback)
                // 不可读文件 → fail-closed + 告警标志。
                try Data([0xFF, 0xFE]).write(to: url)
                let broken = KeybindingRegistry.load(userURL: url)
                try expectTrue(broken.usedFallback)
                try expectEqual(broken.specs.count, 19)
            },
        ]
    }
}
