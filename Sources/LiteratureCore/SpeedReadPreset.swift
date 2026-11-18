import Foundation

// MARK: - 四段式速读预设档案（固定四问＋固定段式＋页码锚点）

public enum SpeedReadPreset {
    /// 字符预算（选中块总 snippet 预算；常数集中一处）。
    public static let speedReadCharBudget = 6000

    /// 段式标题（固定顺序；解析与渲染共用）。
    public static let sectionTitles = ["背景", "前人不足", "方法", "结论"]

    // 四问自写模板（本库原创文案）。
    static let questionBackground = "这项研究处于什么背景之下？它要解决的具体问题是什么？"
    static let questionPastWork = "在这一问题上前人已有哪些方法与结论？它们的不足或局限在哪里？作者开展这项研究的动机是否成立？"
    static let questionMethod = "本文提出了什么方法来应对上述不足？其核心思路与关键设计是什么？"
    static let questionResults = "作者在什么任务上得到了什么结果？这些结果能否支撑其研究目标？请对该支撑关系作出批判性判断，而不是复述作者的自述。"

    /// 段式指令（自写）：固定四段 Markdown 标题＋每段末尾页码锚点。
    static let formatInstruction: String = """
    请严格按以下四段格式输出，每段以「### 」标题开头，顺序固定，不要增删段落：
    ### 背景
    ### 前人不足
    ### 方法
    ### 结论
    每段末尾用「（依据：<bookId> 第 <页码> 页）」标注该段论据来自哪些证据块；只准引用所给证据块（passages），证据不含的内容如实写「证据不足」，不要编造。
    """

    /// 问题全文（四问＋段式指令；用户附加关注点非空时追加）。
    public static func questionText(focus: String?) -> String {
        var lines: [String] = [
            "请对下面的证据块作四段式速读，依次回答四个问题：",
            "1. \(questionBackground)",
            "2. \(questionPastWork)",
            "3. \(questionMethod)",
            "4. \(questionResults)",
            formatInstruction,
        ]
        let trimmedFocus = focus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedFocus.isEmpty {
            lines.append("用户附加关注点（回答时优先覆盖）：\(trimmedFocus)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: 问题构造（纯）

public enum SpeedReadQuestionBuilder {
    /// 合成速读 question（四问全文＋段式指令；selections 用于声明证据块
    /// 数量与可引用书目，载荷本体仍走综合通道的 selections 字段）。
    public static func build(selections: [AIPreview.Selection], question: String = "") -> String {
        let bookIDs = Array(Set(selections.map(\.bookID))).sorted()
        var base = SpeedReadPreset.questionText(focus: question)
        if !bookIDs.isEmpty {
            base += "\n证据块来自书目：\(bookIDs.joined(separator: "、"))（共 \(selections.count) 段）。"
        }
        return base
    }
}


public enum SpeedReadBudget {
    public struct Outcome: Equatable, Sendable {
        public let selections: [AIPreview.Selection]
        /// 被裁掉的字符总数（如实计数）。
        public let droppedCharCount: Int
        public let truncated: Bool
    }

    /// 超预算按序均匀截断：每个块分得 budget/count 字符份额，超出部分
    /// 截去并累计如实计数（不静默丢块）。
    public static func trim(selections: [AIPreview.Selection],
                            charBudget: Int = SpeedReadPreset.speedReadCharBudget) -> Outcome {
        guard !selections.isEmpty, charBudget > 0 else {
            return Outcome(selections: selections, droppedCharCount: 0, truncated: false)
        }
        let total = selections.reduce(0) { $0 + $1.snippet.count }
        guard total > charBudget else {
            return Outcome(selections: selections, droppedCharCount: 0, truncated: false)
        }
        let share = max(1, charBudget / selections.count)
        var dropped = 0
        let trimmed = selections.map { selection -> AIPreview.Selection in
            guard selection.snippet.count > share else { return selection }
            dropped += selection.snippet.count - share
            var copy = selection
            copy.snippet = String(selection.snippet.prefix(share))
            return copy
        }
        return Outcome(selections: trimmed, droppedCharCount: dropped, truncated: true)
    }
}

// MARK: 结果解析（纯）

/// 单段：标题＋正文＋页码锚点。缺段如实（isMissing）。
public struct SpeedReadSection: Equatable, Sendable {
    public let title: String
    public let text: String
    /// 从「（依据：bookId 第 N 页）」抽取的锚点（bookId＋物理页）。
    public let anchors: [SpeedReadAnchor]
    public let isMissing: Bool
}

public struct SpeedReadAnchor: Equatable, Sendable {
    public let bookID: String
    public let page: Int
}

public struct SpeedReadCard: Equatable, Sendable {
    /// 恒为段式标题顺序的四段（缺失段 isMissing=true）。
    public let sections: [SpeedReadSection]
}

public enum SpeedReadCardParser {
    /// 「（依据：<bookId> 第 <N> 页）」锚点（自写契约）。
    static let anchorPattern = "（依据：\\s*([^（）：:）\\s]+)\\s*第\\s*(\\d+)\\s*页\\s*）"

    /// 解析速读卡：按段式标题定位四段（段序乱仍按标题归位，输出恒为
    /// 预设顺序）；缺段如实 isMissing；整篇找不到任何段式标题＝解析失败
    /// 返回 nil（调用方整卡降级为普通 answer 显示，不崩不编造）。
    public static func parse(answerText: String) -> SpeedReadCard? {
        let lines = answerText.components(separatedBy: "\n")
        // 每行定位段标题：以「###」开头且含段式标题（容忍冒号/空格变体）。
        var found: [String: (start: Int, end: Int)] = [:]  // title -> line range
        var order: [String] = []
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            for title in SpeedReadPreset.sectionTitles where trimmed.contains(title) {
                if found[title] == nil {
                    found[title] = (idx, idx)
                    order.append(title)
                }
            }
        }
        guard !found.isEmpty else { return nil }
        // 段正文范围：标题行下一行到下一个段标题行（或文末）。
        let sortedHeads = order.sorted { found[$0]!.start < found[$1]!.start }
        var sections: [SpeedReadSection] = []
        for title in SpeedReadPreset.sectionTitles {
            guard let head = found[title] else {
                sections.append(SpeedReadSection(title: title, text: "", anchors: [], isMissing: true))
                continue
            }
            let position = sortedHeads.firstIndex(of: title) ?? 0
            let end: Int
            if position + 1 < sortedHeads.count {
                end = found[sortedHeads[position + 1]]!.start
            } else {
                end = lines.count
            }
            let body = lines[(head.start + 1)..<end]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append(SpeedReadSection(title: title, text: body,
                                             anchors: extractAnchors(in: body), isMissing: false))
        }
        return SpeedReadCard(sections: sections)
    }

    /// 抽取段内全部页码锚点（bookId＋物理页；显示层再经 PageNumberService
    /// 换算 pageLabel/printedPage，未知显式「页码未知」）。
    public static func extractAnchors(in text: String) -> [SpeedReadAnchor] {
        guard let regex = try? NSRegularExpression(pattern: anchorPattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var anchors: [SpeedReadAnchor] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  match.numberOfRanges == 3,
                  let bookRange = Range(match.range(at: 1), in: text),
                  let pageRange = Range(match.range(at: 2), in: text),
                  let page = Int(text[pageRange]) else { return }
            anchors.append(SpeedReadAnchor(bookID: String(text[bookRange]), page: page))
        }
        return anchors
    }
}
