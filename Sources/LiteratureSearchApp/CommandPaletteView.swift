import SwiftUI
import AppKit
import LiteratureSearchUI

struct CommandPaletteView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dsTheme) private var theme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    @State private var query = ""
    @State private var selection = 0
    @State private var keyMonitor: Any?

    private struct Command: Identifiable {
        let id: String
        let title: String
        let icon: String
        /// Lowercased extra match surface (keywords beyond the title).
        let keywords: String
        let action: () -> Void
    }

    private var commands: [Command] {
        [
            Command(id: "focus-search", title: L10n.paletteCmdFocusSearch, icon: "magnifyingglass",
                    keywords: "search jujiao") {
                state.sidebarSection = .search
                state.focusSearchRequest += 1
            },
            Command(id: "focus-reading", title: L10n.paletteCmdFocusReading, icon: "rectangle.expand.vertical",
                    keywords: "focus reading zhuanzhu") {
                state.focusReading.toggle()
            },
            Command(id: "theme", title: L10n.paletteCmdTheme, icon: "circle.lefthalf.filled",
                    keywords: "theme zhuti waiguan") {
                rotateTheme()
            },
            Command(id: "library", title: L10n.paletteCmdLibrary, icon: "books.vertical",
                    keywords: "library shuku daoru") {
                state.sidebarSection = .library
            },
            Command(id: "coverage", title: L10n.paletteCmdCoverage, icon: "chart.pie",
                    keywords: "coverage fugai") {
                state.sidebarSection = .coverage
            },
            Command(id: "history", title: L10n.paletteCmdHistory, icon: "clock",
                    keywords: "history lishi") {
                state.sidebarSection = .history
            },
            Command(id: "favorites", title: L10n.paletteCmdFavorites, icon: "star",
                    keywords: "favorites shoucang") {
                state.sidebarSection = .favorites
            },
            Command(id: "quote", title: L10n.paletteCmdQuote, icon: "text.quote",
                    keywords: "quote meiri") {
                state.sidebarSection = .quote
            },
        ]
    }

    private var filtered: [Command] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.filter { $0.title.lowercased().contains(q) || $0.keywords.contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                    .accessibilityHidden(true) // 装饰：搜索框前导图形
                TextField(L10n.palettePlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                Text("⌘K")
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)

            Hairline()

            ScrollView {
                LazyVStack(spacing: 0) {
                    if filtered.isEmpty {
                        Text(L10n.paletteEmpty)
                            .font(.callout)
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                            .frame(maxWidth: .infinity)
                            .padding(DS.Spacing.md)
                    } else {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                            Button {
                                command.action()
                                dismiss()
                            } label: {
                                HStack(spacing: DS.Spacing.sm) {
                                    Image(systemName: command.icon)
                                        .font(.caption)
                                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                                        .frame(width: 16)
                                        .accessibilityHidden(true) // 装饰：按钮文字已述
                                    Text(command.title)
                                        .font(.callout)
                                        .foregroundStyle(DS.Color.ink(theme, scheme))
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, DS.Spacing.md)
                                .padding(.vertical, DS.Spacing.sm)
                                .contentShape(Rectangle())
                                .background(selection == index
                                    ? DS.Color.selectTint(theme, scheme)
                                    : Color.clear)
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { selection = index }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 480)
        .background(DS.Color.surface(theme), in: RoundedRectangle(cornerRadius: DS.Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium)
            .stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .dsAppear()
        .onAppear {
            selection = 0
            installKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onChange(of: query) { _ in
            selection = 0
        }
        .onTapGesture { /* absorb clicks on the panel itself */ }
    }

    /// 轮换主题：跟随系统 → 墨灰 → 玄青 → 跟随系统（写回 dsTheme AppStorage，
    /// RootView 的 .id(dsTheme) 重建链与既有设置页完全一致）。
    private func rotateTheme() {
        switch DS.Theme.storage(dsTheme) {
        case .system: dsTheme = DS.Theme.graphite.rawValue
        case .graphite: dsTheme = DS.Theme.obsidian.rawValue
        case .obsidian: dsTheme = DS.Theme.system.rawValue
        }
    }

    private func dismiss() {
        state.palettePresented = false
    }

    private func runSelection() {
        guard filtered.indices.contains(selection) else { return }
        filtered[selection].action()
        dismiss()
    }

    /// ↑↓ 移动选中、Enter 执行、ESC 关闭（面板打开期间局部监视）。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            switch event.keyCode {
            case 53: // ESC
                dismiss()
                return nil
            case 125: // ↓
                if !filtered.isEmpty { selection = (selection + 1) % filtered.count }
                return nil
            case 126: // ↑
                if !filtered.isEmpty { selection = (selection - 1 + filtered.count) % filtered.count }
                return nil
            case 36, 76: // Enter / numpad Enter
                runSelection()
                return nil
            default:
                return event
            }
        }
    }
}
