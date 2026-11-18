import SwiftUI
import LiteratureCore

// MARK: - 键位桥（SwiftUI 侧映射）
//
// 本文件是全仓唯一允许出现 `.keyboardShortcut(` 的文件（DesignGuard 守卫；
// 两处语义键 `.cancelAction` / `.defaultAction` 豁免单列于原调用点）。
// 注册表本体在 LiteratureCore/KeybindingRegistry.swift（纯 Foundation）；
// 本桥只做「注册表 spec → SwiftUI KeyEquivalent/EventModifiers」的薄映射，
// 无任何键位决策逻辑（键位债务不再生：新快捷键不进注册表即守卫 fail）。

/// 桥产物：SwiftUI 快捷键对。
struct KeybindingShortcut: Equatable {
    let key: KeyEquivalent
    let modifiers: EventModifiers
}

enum KeybindingBridge {
    /// 注册表查询 → SwiftUI 快捷键；禁绑/未注册返回 nil（按钮不挂快捷键）。
    static func shortcut(for action: String, context: String,
                         in registry: KeybindingRegistry?) -> KeybindingShortcut? {
        guard let registry,
              let spec = registry.shortcut(for: action, context: context),
              let ch = spec.key.first else { return nil }
        var mods: EventModifiers = []
        for m in spec.modifiers {
            switch m {
            case "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "option": mods.insert(.option)
            case "control": mods.insert(.control)
            default: break
            }
        }
        return KeybindingShortcut(key: KeyEquivalent(ch), modifiers: mods)
    }

    /// 诊断列表用展示串（⌘⇧1 形式；修饰键规范序 → 符号序）。
    static func displayString(_ spec: KeybindingSpec) -> String {
        let symbols = ["control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘"]
        let prefix = spec.modifiers.compactMap { symbols[$0] }.joined()
        return prefix + spec.key.uppercased()
    }
}


private struct KeybindingsEnvironmentKey: EnvironmentKey {
    static let defaultValue: KeybindingRegistry = .builtin()
}

extension EnvironmentValues {
    /// 键位注册表（RootView 根部注入；子树任意按钮可经 registeredShortcut 接入）。
    var keybindings: KeybindingRegistry {
        get { self[KeybindingsEnvironmentKey.self] }
        set { self[KeybindingsEnvironmentKey.self] = newValue }
    }
}

/// 键位接入 modifier：按 action 查注册表应用快捷键；禁绑 = 无快捷键
///（Sumatra CmdNone 语义），未注册 = 无快捷键（守卫使新快捷键必须进表）。
///
/// SwiftUI `Scene.commands` 不继承
/// WindowGroup 内容树的环境值——app 域菜单命令必须经 `registry:` 显式传
/// `state.keybindings`，否则用户覆盖/禁绑在菜单上静默失效。内容树内
/// （reader 域等）不传 registry、走环境注入，两路同源（AppState 单例）。
struct RegisteredShortcutModifier: ViewModifier {
    let action: String
    let context: String
    var registry: KeybindingRegistry?

    @Environment(\.keybindings) private var environmentRegistry

    func body(content: Content) -> some View {
        let effective = registry ?? environmentRegistry
        if let ks = KeybindingBridge.shortcut(for: action, context: context, in: effective) {
            content.keyboardShortcut(ks.key, modifiers: ks.modifiers)
        } else {
            content
        }
    }
}

extension View {
    /// 键位注册表接入点：Scene.commands 内必须显式传 `registry:`（环境不
    /// 继承）；WindowGroup 内容树内可省略（走环境注入，reader 域显式传 context）。
    func registeredShortcut(_ action: String, context: String = "app",
                            registry: KeybindingRegistry? = nil) -> some View {
        modifier(RegisteredShortcutModifier(action: action, context: context, registry: registry))
    }
}
