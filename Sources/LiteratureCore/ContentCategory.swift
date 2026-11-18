import Foundation

// 内容类别体系。四类=著作/论文/词条/工具书。
// 归类依据只有两样：工具书词表（命中书名）与可配置的文件夹名
// （ContentCategoryFolders，默认全空＝不启用路径归类）。
// 工具书词表判定优先于路径规则——一本工具书即使放在普通书里也仍判工具书。
enum ContentCategory: String, CaseIterable {
    case book     = "著作"
    case paper    = "论文"
    case entry    = "词条"
    case toolbook = "工具书"
}

/// 路径归类的文件夹名配置。默认全为空数组，即"未知/未分类"，
/// 用户可按自己的目录命名填写（无设置界面，由宿主程序注入）。
public struct ContentCategoryFolders: Equatable {
    public var books: [String]
    public var papers: [String]
    public var entries: [String]

    public init(books: [String] = [], papers: [String] = [], entries: [String] = []) {
        self.books = books
        self.papers = papers
        self.entries = entries
    }

    /// 进程内可注入的当前配置；默认空（不启用路径归类）。
    public static var current = ContentCategoryFolders()
}

/// 路径是否落在给定文件夹名之下（按路径段全等匹配，空数组恒不命中）。
func contentCategoryPathMatches(_ path: String, _ folderNames: [String]) -> Bool {
    guard !folderNames.isEmpty else { return false }
    let segments = path.split(separator: "/").map(String.init)
    return folderNames.contains { name in
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return !trimmed.isEmpty && segments.contains(trimmed)
    }
}

/// 工具书词表默认值（外置可编辑的初始集；命中书名即判工具书）。
public let toolbookLexiconDefault: [String] = ["引注手册", "翻译大辞典", "百科全书", "辞典", "年鉴"]

/// 按书名与路径归类的纯函数。优先级：工具书词表 > 路径目录。
/// 无命中 → 空串（未知类别，检索 fail-open 收录）。
func classifyContentCategory(path: String, title: String, toolbookLexicon: [String] = toolbookLexiconDefault) -> String {
    func strippingPublisherSegments(_ s: String) -> String {
        // 剔除「……出版社」整段（社名前无分隔符的连续串），社名后缀的
        // 年份/版次/pdf 保留无碍——词表只对剩余书名段生效。
        guard let regex = try? NSRegularExpression(pattern: "[^，,；;（）()\\n]*出版社") else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
    let titleForMatch = strippingPublisherSegments(title)
    let pathForMatch = strippingPublisherSegments(path)
    let haystack = titleForMatch + " " + pathForMatch
    if toolbookLexicon.contains(where: { !$0.isEmpty && haystack.contains($0) }) {
        return ContentCategory.toolbook.rawValue
    }
    let folders = ContentCategoryFolders.current
    if contentCategoryPathMatches(path, folders.books)   { return ContentCategory.book.rawValue }
    if contentCategoryPathMatches(path, folders.papers)  { return ContentCategory.paper.rawValue }
    if contentCategoryPathMatches(path, folders.entries) { return ContentCategory.entry.rawValue }
    return ""
}

/// 检索收录判定：四类中工具书由开关控制；空类别 fail-open 收录。
func searchShouldInclude(category: String, includeToolBooks: Bool) -> Bool {
    switch category {
    case ContentCategory.toolbook.rawValue:
        return includeToolBooks
    default:
        return true
    }
}
