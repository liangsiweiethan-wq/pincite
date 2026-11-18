import Foundation

// MARK: - Annotation ingest plan
//
// 快速批注（侧边批注面板输入框）与「AI 回答存为批注」共用的写入参数
// 归一：有选区 → 锚选区（HighlightStore.add，anchor = 选中文本）；
// 无选区 → 页级批注（HighlightStore.addPageNote，无坐标锚点）。
// 纯逻辑、零 I/O，便于合成测试锁两分支语义；真正落库仍只经 HighlightStore。

public enum AnnotationPlan: Sendable {

    /// AI 回答入库的轻标记前缀（侵入最小——不加列、不改 schema，note 文本
    /// 自带来源标识；批注列表按前缀即可识别 AI 产出）。
    public static let aiNotePrefix = "[AI] "

    /// 归一后的写入计划。App 层据此调用：
    /// `isPageNote == true` → `addPageNote(bookID:pageNumber:note:viewSource:)`
    /// （其 utf16 字段无意义，仅占位）；否则 `add(bookID:pageNumber:utf16Start:
    /// utf16End:color:note:anchorText:viewSource:)`。
    public struct Ingest: Equatable, Sendable {
        /// true = 页级批注（无选区分支）。
        public let isPageNote: Bool
        public let pageNumber: Int
        public let utf16Start: Int
        public let utf16End: Int
        public let anchorText: String
        public let note: String
        public let viewSource: String

        public init(isPageNote: Bool, pageNumber: Int, utf16Start: Int, utf16End: Int,
                    anchorText: String, note: String, viewSource: String) {
            self.isPageNote = isPageNote
            self.pageNumber = pageNumber
            self.utf16Start = utf16Start
            self.utf16End = utf16End
            self.anchorText = anchorText
            self.note = note
            self.viewSource = viewSource
        }
    }

    /// - Parameters:
    ///   - selectionPage: 选区所在物理页（1 起）；nil = 无选区。
    ///   - selectionRange: 选区 utf16 区间（与 selectionPage 同一文件同源）。
    ///   - selectionText: 选中文本（截 200 作抗漂移锚点；空串视为无锚）。
    ///   - currentPage: 当前阅读页（1 起；0 = 未落地）。
    ///   - note: 批注正文原样入库（AI 前缀由调用方拼 `aiNotePrefix`）。
    /// - viewSource: 视图来源（'ocr'/'original'；store 侧再归一降级处理）。
    /// 返回 nil = 参数不可写：无选区且当前页未落地（fail-closed，不静默猜页）。
    public static func make(selectionPage: Int?, selectionRange: Range<Int>?, selectionText: String?,
                            currentPage: Int, note: String,
                            viewSource: String) -> Ingest? {
        if let page = selectionPage, page >= 1,
           let range = selectionRange, !range.isEmpty, range.lowerBound >= 0,
           let text = selectionText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Ingest(
                isPageNote: false, pageNumber: page,
                utf16Start: range.lowerBound, utf16End: range.upperBound,
                anchorText: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
                note: note, viewSource: viewSource)
        }
        guard currentPage >= 1 else { return nil }
        return Ingest(
            isPageNote: true, pageNumber: currentPage,
            utf16Start: 0, utf16End: 0, anchorText: "",
            note: note, viewSource: viewSource)
    }
}
