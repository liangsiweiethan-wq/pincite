import Foundation


/// 段级落点三元组（书/页/段）；引文归因与证据集合用。
public struct SemanticAnchor: Hashable, Codable, Sendable {
    public let bookID: String
    /// 物理页（1 起）。
    public let page: Int
    /// 页内 0 起段序。
    public let paraIndex: Int

    public init(bookID: String, page: Int, paraIndex: Int) {
        self.bookID = bookID
        self.page = page
        self.paraIndex = paraIndex
    }
}

public extension ReferenceResolver {
    /// 段级引文判定：para nil → 页级现状语义逐字节不变（委托 resolve）；
    /// para 非 nil → 页级判定先过，再要求段号在该书该页证据段集合内。
    static func resolveWithParagraphs(_ references: [AIReference],
                                      allowedSources: [AllowedSource],
                                      evidenceParagraphs: Set<SemanticAnchor>) -> [ReferenceDecision] {
        let pageLevel = resolve(references, allowedSources: allowedSources)
        return pageLevel.enumerated().map { index, decision in
            guard case .accepted(let bookID, let page) = decision,
                  let para = references[index].para else { return decision }
            let anchor = SemanticAnchor(bookID: bookID, page: page, paraIndex: para)
            guard evidenceParagraphs.contains(anchor) else {
                return .rejected(bookID: bookID, page: page, reason: "paragraph not in request evidence")
            }
            return decision
        }
    }
}
