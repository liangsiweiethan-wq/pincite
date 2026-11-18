import SwiftUI
import AppKit
import LiteratureSearchUI

struct ColumnShell<Sidebar: View, Content: View, Detail: View>: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let sidebar: Sidebar
    let content: Content
    let detail: Detail

    @State private var dragBase: (column: AppState.Column, width: CGFloat)?

    var body: some View {
        HStack(spacing: 0) {
            if state.sidebarColumnVisible {
                sidebar
                    .frame(width: state.sidebarColumnWidth)
                    .clipped()
                divider(for: .sidebar)
            }
            if state.resultsColumnVisible {
                content
                    .frame(width: state.resultsColumnWidth)
                    .clipped()
                divider(for: .detail)
            }
            if state.detailColumnVisible {
                detail
                    .layoutPriority(1)
            }
        }
        // 原文栏单独最大化时仍保留最小阅读宽。
        .frame(minWidth: AppState.detailColumnMin, alignment: .leading)
    }

    private func divider(for column: AppState.Column) -> some View {
        Rectangle()
            .fill(DS.Color.stroke(theme, scheme))
            .frame(width: 1)
            // 实际命中区比视觉条宽，便于拖动。
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragBase?.column != column {
                            dragBase = (column, adjacentWidth(of: column))
                        }
                        guard let base = dragBase else { return }
                        applyDrag(column: column, startWidth: base.width, delta: value.translation.width)
                    }
                    .onEnded { _ in dragBase = nil }
            )
            .onTapGesture(count: 2) {
                // 双击分隔条回相邻列 ideal 宽。
                withAnimation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.duration)) { resetAdjacentWidth(of: column) }
            }
            .accessibilityLabel(L10n.columnDividerAccessibility)
    }

    /// 该分隔条拖拽时实际调整的列：两条分隔条分别对应侧栏、结果栏。
    private func adjacentWidth(of column: AppState.Column) -> CGFloat {
        switch column {
        case .sidebar: return state.sidebarColumnWidth
        case .detail: return state.resultsColumnWidth
        case .results: return state.resultsColumnWidth
        }
    }

    private func applyDrag(column: AppState.Column, startWidth: CGFloat, delta: CGFloat) {
        switch column {
        case .sidebar:
            state.sidebarColumnWidth = clamp(startWidth + delta,
                                             lo: AppState.sidebarColumnMin, hi: AppState.sidebarColumnMax)
        case .results, .detail:
            state.resultsColumnWidth = clamp(startWidth + delta,
                                             lo: AppState.resultsColumnMin, hi: AppState.resultsColumnMax)
        }
    }

    private func resetAdjacentWidth(of column: AppState.Column) {
        switch column {
        case .sidebar: state.sidebarColumnWidth = 200
        case .results, .detail: state.resultsColumnWidth = 520
        }
    }

    private func clamp(_ v: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(v, lo), hi)
    }
}
