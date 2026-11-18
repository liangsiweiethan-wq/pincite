import SwiftUI
import LiteratureCore
import LiteratureSearchUI

/// 本书用户高亮列表（管理入口，详情栏「我的高亮」按钮弹出）。
struct UserHighlightsListView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let bookID: String

    @State private var highlights: [UserHighlight] = []
    /// 备注编辑草稿（key = 高亮 id；回车提交 updateNote）。
    @State private var noteDrafts: [Int64: String] = [:]
    @State private var confirmDelete: UserHighlight?
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.highlightsPopoverTitle)
                    .font(DS.Font.displayGroup)
                    .foregroundStyle(DS.Color.ink(theme, scheme))
                Spacer()
                Button(L10n.highlightsExportButton) { exportMarkdown() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(highlights.isEmpty)
                    .help(highlights.isEmpty ? L10n.highlightsEmpty : L10n.highlightsExportButton)
                    .accessibilityLabel(L10n.highlightsExportButton)
                if let notice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)

            if highlights.isEmpty {
                // 走查：自绘空态收敛到 EmptyStateView 同等规格（衬线标题
                // + 印章红刻痕条），图标用高亮笔触符号。
                EmptyStateView(systemImage: "highlighter", title: L10n.highlightsEmpty)
            } else {
                List(highlights) { highlight in
                    row(for: highlight)
                        .listRowSeparator(.visible)
                }
                .listStyle(.plain)
            }
        }
        .onAppear(perform: reload)
        .alert(item: $confirmDelete) { highlight in
            Alert(
                title: Text(L10n.highlightsDeleteConfirmTitle),
                message: Text(L10n.highlightsDeleteConfirmMessage),
                primaryButton: .destructive(Text(L10n.actionDelete)) {
                    delete(highlight)
                },
                secondaryButton: .cancel(Text(L10n.aiCancelSend)))
        }
    }

    @ViewBuilder
    private func row(for highlight: UserHighlight) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Button {
                Task { await state.openBookPage(bookID: highlight.bookID, pageNumber: highlight.pageNumber) }
            } label: {
                HStack(alignment: .top, spacing: DS.Spacing.xs) {
                    Circle()
                        .fill(color(for: highlight.color))
                        .frame(width: 10, height: 10)
                        .padding(.top, 4)
                        .accessibilityLabel(L10n.highlightsColorAccessibility)
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        HStack(spacing: DS.Spacing.xxs) {
                            Text(L10n.highlightsPageLabel(highlight.pageNumber))
                                .font(.caption)
                                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                            // 样式指示（高亮/下划线）。
                            Label(highlight.style == "underline" ? L10n.underlineAction : L10n.highlightAction,
                                  systemImage: highlight.style == "underline" ? "underline" : "highlighter")
                                .font(.caption2)
                                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                                .labelStyle(.titleAndIcon)
                        }
                        let snip = snippet(for: highlight)
                        Text(snip)
                            .font(.callout)
                            .foregroundStyle(snip == L10n.highlightsStaleSnippet ? DS.Color.inkSecondary(theme, scheme) : DS.Color.ink(theme, scheme))
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Menu {
                    Button(L10n.menuHighlightYellow) { recolor(highlight, .yellow) }
                    Button(L10n.menuHighlightGreen) { recolor(highlight, .green) }
                    Button(L10n.menuHighlightBlue) { recolor(highlight, .blue) }
                    Button(L10n.menuHighlightRed) { recolor(highlight, .red) }
                } label: {
                    Label(L10n.highlightsColorAccessibility, systemImage: "paintpalette")
                }
                // 高亮 ⇄ 下划线切换（样式入库，版本号重贴）。
                Button(highlight.style == "underline" ? L10n.changeToHighlight : L10n.changeToUnderline) {
                    toggleStyle(highlight)
                }
                Divider()
                Button(L10n.actionDelete) { confirmDelete = highlight }
            }
            TextField(L10n.highlightsNotePlaceholder,
                      text: draftBinding(for: highlight))
                .font(.caption)
                .textFieldStyle(.dsTextField)
                .onSubmit { saveNote(highlight) }
        }
        .padding(.vertical, DS.Spacing.xs)
        .dsHoverFade()
    }

    // MARK: Data

    private func reload() {
        guard let store = state.highlightStore else { return }
        let loaded = (try? store.verifiedHighlightsForBook(bookID)) ?? (try? store.highlightsForBook(bookID)) ?? []
        highlights = loaded
        var drafts: [Int64: String] = [:]
        for highlight in loaded { drafts[highlight.id] = highlight.note }
        noteDrafts = drafts
    }

    private func delete(_ highlight: UserHighlight) {
        // 删除改软删 + toast 撤销（唯一通道 AppState.requestAnnotation
        // Delete——softDelete → notice → 5 秒窗口；既有确认弹窗保留不动，焦虑
        // 防线在事前确认之上再加事后撤销）。回执由全局 toast 呈现，本地 flash
        // 不再重复。
        state.requestAnnotationDelete(highlight)
        reload()
    }

    private func recolor(_ highlight: UserHighlight, _ color: HighlightColor) {
        guard let store = state.highlightStore else { return }
        do {
            try store.updateColor(id: highlight.id, color: color)
            state.highlightsVersion &+= 1
            reload()
            flash(L10n.highlightsUpdated)
        } catch { reload() }
    }

    private func toggleStyle(_ highlight: UserHighlight) {
        guard let store = state.highlightStore else { return }
        let next = highlight.style == "underline" ? "highlight" : "underline"
        do {
            try store.updateAppearance(id: highlight.id, color: highlight.color, style: next)
            state.highlightsVersion &+= 1
            reload()
            flash(L10n.highlightsUpdated)
        } catch { reload() }
    }

    private func saveNote(_ highlight: UserHighlight) {
        guard let store = state.highlightStore,
              noteDrafts[highlight.id] != highlight.note else { return }
        do {
            try store.updateNote(id: highlight.id, note: noteDrafts[highlight.id] ?? "")
            state.highlightsVersion &+= 1
            reload()
            flash(L10n.highlightsUpdated)
        } catch { reload() }
    }

    // MARK: Export (唯一写盘点 = NSSavePanel 用户所选 .md；原书 PDF 不碰)

    private func exportMarkdown() {
        guard !highlights.isEmpty else {
            flash(L10n.highlightsEmpty)
            return
        }
        guard let export = state.highlightsExportMarkdown(bookID: bookID) else {
            flash(L10n.highlightsExportFailed)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L10n.highlightsExportFileName(export.title)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try export.markdown.write(to: url, atomically: true, encoding: .utf8)
            flash(L10n.highlightsExportButton)
        } catch {
            flash(L10n.highlightsExportFailed)
        }
    }

    private func snippet(for highlight: UserHighlight) -> String {
        if highlight.anchorVerified == -1 {
            return L10n.highlightsStaleSnippet
        }
        let text = state.highlightSnippet(bookID: highlight.bookID,
                                          pageNumber: highlight.pageNumber,
                                          range: highlight.utf16Start..<highlight.utf16End)
        if let text, !text.isEmpty {
            if !highlight.anchorText.isEmpty && text != highlight.anchorText {
                return L10n.highlightsStaleSnippet
            }
            return text
        }
        if !highlight.anchorText.isEmpty {
            return L10n.highlightsStaleSnippet
        }
        return L10n.favoritesPageLine(highlight.pageNumber)
    }

    private func flash(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if notice == text { notice = nil }
        }
    }

    private func draftBinding(for highlight: UserHighlight) -> Binding<String> {
        Binding(
            get: { noteDrafts[highlight.id] ?? "" },
            set: { noteDrafts[highlight.id] = $0 })
    }

    private func color(for highlightColor: HighlightColor) -> Color {
        var s = highlightColor.colorHex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .yellow }
        return Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}
