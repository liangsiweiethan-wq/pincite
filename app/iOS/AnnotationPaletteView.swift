import SwiftUI

// MARK: - 批注调色板（PDF Expert 分级：常用四色一级 + 全色板
// 抽屉二级；笔宽两档；笔型 pen/marker。取值全部来自 Core
// InkToolSelection——工具选择↔PKToolPicker 映射的纯函数半边有测试断言固定）

struct AnnotationPaletteView: View {
    @Binding var selection: InkToolSelection
    @State private var showDrawer = false

    var body: some View {
        HStack(spacing: 10) {
            ForEach(InkToolSelection.primaryColors, id: \.self) { hex in
                Button {
                    selection.colorHex = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: selection.colorHex == hex ? 26 : 20,
                               height: selection.colorHex == hex ? 26 : 20)
                        .overlay(Circle().stroke(Color.primary.opacity(selection.colorHex == hex ? 0.6 : 0),
                                                 lineWidth: 1.5))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(hex)
            }
            Divider().frame(height: 20)
            ForEach(InkToolSelection.lineWidths, id: \.self) { width in
                Button {
                    selection.lineWidth = width
                } label: {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: width, height: width)
                        .opacity(selection.lineWidth == width ? 1 : 0.35)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(format: "%.0fpt", width))
            }
            Divider().frame(height: 20)
            ForEach(InkTool.allCases, id: \.rawValue) { tool in
                Button {
                    selection.tool = tool
                } label: {
                    Image(systemName: Self.icon(tool))
                        .opacity(selection.tool == tool ? 1 : 0.4)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(tool.rawValue)
            }
            Spacer()
            Button {
                showDrawer.toggle()
            } label: {
                Image(systemName: showDrawer ? "paintpalette.fill" : "paintpalette")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// 工具 → SF Symbol（橡皮工具）。
    private static func icon(_ tool: InkTool) -> String {
        switch tool {
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .eraser: return "eraser"
        }
    }
}
