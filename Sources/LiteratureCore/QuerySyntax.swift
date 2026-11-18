import Foundation

// MARK: - 查询语法层（纯解析＋求值翻译；引擎零触碰）

public enum QuerySyntaxError: Error, Equatable, CustomStringConvertible {
    /// 正则匹配超时（1.0s 闸）。pattern 为用户原始输入（诊断记录）。
    case regexTimeout(pattern: String)
    /// 正则 pattern 编译失败（fail-closed：无效正则报错，不静默零命中）。
    case invalidRegex(pattern: String, underlying: String)

    public var description: String {
        switch self {
        case .regexTimeout(let p): return "正则超时（>1.0s，已按该子句不命中处理）: \(p)"
        case .invalidRegex(let p, let u): return "正则无效: \(p) — \(u)"
        }
    }
}

/// 正则档超时闸（秒）。常量在位即是该规则的落点。
public let querySyntaxRegexTimeout: TimeInterval = 1.0

/// 正则档查询级熔断：实例挂 SyntaxQueryPlan 沿调用链传递——
/// 静态可变态与并发化冲突：并发查询 reset/charge 互踩＋数据竞争）。
/// 单查询累计正则耗时达 maxTotalSeconds 或超时页数达 maxTimeoutPages，
/// 本查询余下正则求值整体短路（按不命中处理并如实记超时标注）——防
/// 「大量页 × 各自 1s 闸」的面积性挂滞。每页 1.0s 独立闸不变。
/// 单查询内正则求值与页循环同序串行，实例无需同步。
public final class RegexBudget {
    public static let maxTotalSeconds: TimeInterval = 5.0
    public static let maxTimeoutPages = 20
    private var elapsedSeconds: TimeInterval = 0
    private var timeoutPages = 0
    public init() {}
    func charge(seconds: TimeInterval) { elapsedSeconds += seconds }
    func recordTimeout() { timeoutPages += 1 }
    var tripped: Bool { elapsedSeconds >= Self.maxTotalSeconds || timeoutPages >= Self.maxTimeoutPages }
}

/// 字段限定支持的字段集（中文标签；帮助文案写明基准）。
public enum QueryFieldKind: String, CaseIterable, Equatable {
    case author = "作者"
    case title = "书名"
    case language = "语言"
    case version = "版本"
    case tag = "标签"
    case source = "来源"
}

/// 字段/自由词谓词三档。contains/equals 大小写不敏感（与 SearchFilter
/// 既有基准一致：localizedCaseInsensitiveContains / caseInsensitiveCompare）。
public enum FieldPredicate: Equatable {
    case contains(String)   // 缺省档：值包含
    case equals(String)     // 精确档：值精确相等（自由词档＝规范化后词边界全词）
    case regex(String)      // 正则档：NSRegularExpression（1.0s 超时闸）
}

/// AST 节点。term/exactTerm/phrase 存规范化后的词（与现行候选通道同基准）；
/// regex 存用户原始 pattern（诊断记录需原文；匹配时在规范化文本上执行）。
public enum QueryNode: Equatable {
    case term(String)            // 缺省档自由词（规范化子串）
    case exactTerm(String)       // 值= 精确自由词（规范化后词边界全词匹配）
    case phrase(String)          // 引号短语（规范化连续子串，单 term）
    case regex(pattern: String)  // 正则自由词档
    case field(field: QueryFieldKind, predicate: FieldPredicate)
}

/// 解析结果。nodes＝隐式 AND 的 item 序列。
public struct ParsedQuery: Equatable {
    public let nodes: [QueryNode]
    /// 是否出现语法字符（SearchService 分派依据的镜像，测试用）。
    public let usedSyntax: Bool

    /// 词项节点（term/phrase/exactTerm）的规范化词序列，按出现顺序。
    /// 无语法查询时与 splitQueryTerms(normalizeQuery(raw)) 逐项相等。
    public var freeTerms: [String] {
        nodes.compactMap { node -> String? in
            switch node {
            case .term(let t), .exactTerm(let t), .phrase(let t): return t
            case .regex, .field: return nil
            }
        }
    }

    public var hasRegex: Bool {
        nodes.contains {
            if case .regex = $0 { return true }
            if case .field(_, .regex) = $0 { return true }
            return false
        }
    }

    /// 字段限定节点。
    public var fieldNodes: [(field: QueryFieldKind, predicate: FieldPredicate)] {
        nodes.compactMap { node in
            if case .field(let f, let p) = node { return (f, p) }
            return nil
        }
    }

    /// 调试面板用的 AST 概要（单行字符串；纯函数，测试断言固定格式）。
    public var summary: String {
        let parts: [String] = nodes.map { node in
            switch node {
            case .term(let t): return "词[\(t)]"
            case .exactTerm(let t): return "精确[\(t)]"
            case .phrase(let t): return "短语[\(t)]"
            case .regex(let p): return "正则[\(p)]"
            case .field(let f, let p):
                let pv: String
                switch p {
                case .contains(let v): pv = "含:\(v)"
                case .equals(let v): pv = "等:\(v)"
                case .regex(let v): pv = "则:\(v)"
                }
                return "字段[\(f.rawValue) \(pv)]"
            }
        }
        return parts.joined(separator: " AND ")
    }
}

public enum QuerySyntax {
    /// 语法字符集（半角）。判定与分派的唯一原书。
    public static let syntaxCharacters: Set<Character> = [":", "=", "~", "\""]

    /// 分派判定：查询串含任一语法字符才进新层。
    /// 在原始查询串上判定（归一化前）——归一化会改写字符（如全角→半角），
    /// 在归一化后判定会让批前走旧路的查询漂进新层。
    public static func hasSyntaxCharacter(_ raw: String) -> Bool {
        raw.contains { syntaxCharacters.contains($0) }
    }

    // MARK: 递归下降解析

    /// 解析入口。除引号未闭合 fail-closed 外永远可解析——语法层只做加法，
    /// 不引入「合法查询被拒」的新失败面。
    public static func parse(_ raw: String) throws -> ParsedQuery {
        var parser = Parser(chars: Array(raw))
        let nodes = try parser.parseSequence()
        return ParsedQuery(nodes: nodes, usedSyntax: hasSyntaxCharacter(raw))
    }


    static func syntaxRoute(term: String, wftsReady: Bool) -> TermRoute {
        guard term.allSatisfy({ $0.isASCII }) else { return .cjkPath }
        guard term.allSatisfy({ ($0.isLetter || $0.isNumber) }) else { return .latinSubstringPath }
        let lowered = term.lowercased()
        if lowered.allSatisfy({ $0.isLetter }), PinyinSyllables.isParseable(lowered) {
            return .latinSubstringPath
        }
        return wftsReady ? .latinWordPath : .latinSubstringPath
    }

    private struct Parser {
        let chars: [Character]
        var pos = 0

        init(chars: [Character]) { self.chars = chars }

        var isAtEnd: Bool { pos >= chars.count }
        mutating func advance() -> Character { let c = chars[pos]; pos += 1; return c }
        func peek() -> Character? { pos < chars.count ? chars[pos] : nil }

        /// parseSequence: = item (whitespace item)* （隐式 AND；一个 item
        /// 可展开为 0..n 个节点，如 `权利~Recht.*` → 词＋正则两节点）
        mutating func parseSequence() throws -> [QueryNode] {
            var nodes: [QueryNode] = []
            while !isAtEnd {
                if let c = peek(), c.isWhitespace { pos += 1; continue }
                nodes.append(contentsOf: try parseItem())
            }
            return nodes
        }

        /// item: = quoted | field | decoratedTerm
        mutating func parseItem() throws -> [QueryNode] {
            guard let c = peek() else { return [] }
            if c == "\"" {
                let quoteStart = pos
                if let phrase = try parseQuoted() { return [.phrase(phrase)] }
                // 未闭合引号：回退到引号处按字面 token 解析（引号并入，
                // parseQuoted 已把光标推到串尾——不回退会产出空 term）。
                pos = quoteStart
                return try parseDecoratedTerm()
            }
            if let fieldNode = try tryParseField() { return [fieldNode] }
            return try parseDecoratedTerm()
        }

        /// "..."：引号短语。引号内语法字符不解析（`"作者:xx"` 是短语不是
        /// 字段）。未闭合不抛错（语法层只做加法——批前查询单个 `"` 走旧
        /// 路是合法字面查询，绝不引入「批前合法查询被拒」的新失败面；
        /// 既有 EdgeCase 契约断言固定），降级：引号并入字面 token 按普通 term。
        mutating func parseQuoted() throws -> String? {
            pos += 1 // 吃掉开引号
            var out = ""
            while !isAtEnd {
                let c = advance()
                if c == "\"" { return normalizeQuery(out) }
                out.append(c)
            }
            return nil   // 未闭合：由调用方按字面 term 处理
        }

        /// 尝试解析 字段名:值（值可带引号、可带 =/~ 档位）。
        mutating func tryParseField() throws -> QueryNode? {
            guard let kind = peekFieldKind() else { return nil }
            pos += kind.rawValue.count + 1 // 吃掉 字段名 + ':'
            if peek() == "\"" {
                guard let v = try parseQuoted() else {
                    // 值引号未闭合：按字面 term（字段名+冒号+引号并入）。
                    return .term(normalizeQuery(kind.rawValue + ":\""))
                }
                // 引号值后可跟档位（作者:"周 慎 之"= 形态）。
                if peek() == "=" {
                    pos += 1
                    return Self.fieldNode(kind, rawValue: v, modifier: "=")
                }
                if peek() == "~" {
                    pos += 1
                    return try parseFieldRegex(kind: kind,
                                               fallback: kind.rawValue + ":\"" + v + "~")
                }
                return Self.fieldNode(kind, rawValue: v, modifier: nil)
            }
            var valueChars: [Character] = []
            var modifier: Character?
            while let c = peek(), !c.isWhitespace {
                if c == "=" || c == "~" { modifier = c; pos += 1; break }
                valueChars.append(c)
                pos += 1
            }
            let rawValue = String(valueChars)
            if modifier == "~" {
                return try parseFieldRegex(kind: kind,
                                           fallback: kind.rawValue + ":" + rawValue + "~")
            }
            guard !rawValue.isEmpty else {
                // `作者:` 无值——按字面 term 处理（不猜）。
                return .term(normalizeQuery(kind.rawValue + ":"))
            }
            return Self.fieldNode(kind, rawValue: rawValue, modifier: modifier)
        }

        /// 字段正则档：`字段:值~Y` / `字段:"值"~Y` / `字段:~Y` ＝ 字段值上
        /// 跑正则 Y（Y ＝ ~ 后余下 token；字段头与 ~ 之间的值前缀不参与
        /// 谓词——字段档正则的谓词对象是字段存储值，见 QueryFilter.evaluate
        mutating func parseFieldRegex(kind: QueryFieldKind, fallback: String) throws -> QueryNode {
            var pattern = ""
            while let c = peek(), !c.isWhitespace {
                pattern.append(c)
                pos += 1
            }
            guard !pattern.isEmpty else {
                return .term(normalizeQuery(fallback))
            }
            do {
                _ = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            } catch {
                throw QuerySyntaxError.invalidRegex(pattern: pattern,
                                                    underlying: String(describing: error))
            }
            return .field(field: kind, predicate: .regex(pattern))
        }

        /// 前瞻扫描：当前 token 是否形如 `字段名:` 且字段名在字段集内。
        /// 纯前瞻（不动 pos）。
        func peekFieldKind() -> QueryFieldKind? {
            var name = ""
            var i = pos
            while i < chars.count {
                let c = chars[i]
                if c == ":" { break }
                if c.isWhitespace || c == "\"" || c == "=" || c == "~" { return nil }
                name.append(c)
                i += 1
            }
            guard i < chars.count, chars[i] == ":" else { return nil }
            return QueryFieldKind(rawValue: name)
        }

        /// 自由词：term / term= / term~regex / ~regex。
        /// `X~Y` → [term(X), regex(Y)]；`~Y` → [regex(Y)]。
        mutating func parseDecoratedTerm() throws -> [QueryNode] {
            var word = ""
            while let c = peek(), !c.isWhitespace {
                if c == "=" || c == "~" { break }
                word.append(c)
                pos += 1
            }
            if peek() == "=" {
                pos += 1
                return [.exactTerm(normalizeQuery(word))]
            }
            if peek() == "~" {
                pos += 1
                // pattern 含 ~ 之后的全部非空白字符（正则语法字符不归一化）。
                var pattern = ""
                while let c = peek(), !c.isWhitespace {
                    pattern.append(c)
                    pos += 1
                }
                guard !pattern.isEmpty else {
                    // `foo~` 孤立尾随修饰符——按字面 term（不猜）。
                    return [.term(normalizeQuery(word + "~"))]
                }
                do {
                    _ = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                } catch {
                    throw QuerySyntaxError.invalidRegex(pattern: pattern,
                                                        underlying: String(describing: error))
                }
                var nodes: [QueryNode] = []
                if !word.isEmpty { nodes.append(.term(normalizeQuery(word))) }
                nodes.append(.regex(pattern: pattern))
                return nodes
            }
            return [.term(normalizeQuery(word))]
        }

        /// 字段谓词组装。字段「值」归一化与自由词同基准；正则 pattern 不
        /// 归一化（归一化会破坏正则语法字符）。
        static func fieldNode(_ kind: QueryFieldKind, rawValue: String,
                              modifier: Character?) -> QueryNode {
            switch modifier {
            case "=": return .field(field: kind, predicate: .equals(normalizeQuery(rawValue)))
            case "~": return .field(field: kind, predicate: .regex(rawValue))
            default: return .field(field: kind, predicate: .contains(normalizeQuery(rawValue)))
            }
        }
    }
}

// MARK: - QueryFilter（字段限定的书级过滤；与 GUI 过滤条 AND 组合）
//
// SearchFilter（SearchService.swift:92-143）一个字节不动的并行结构。
// 设计定名的 authorEquals/authorContains/titleContains/languageEquals/
// versionContains/tagContains/sourceDomain 以谓词表形式承载：
//   authorEquals       ← 作者:值=
//   authorContains     ← 作者:值
//   titleContains      ← 书名:值（含 书名:值= 的精确语义经 .equals 谓词）
//   languageEquals     ← 语言:值 / 语言:值=
//   versionContains    ← 版本:值
//   tagContains        ← 标签:值
//   sourceDomain       ← 来源:值
// 精确档对 title/version/tag/source 同样成立（.equals 谓词逐一承载），
// 谓词表比七个独立字段更防「加字段漏判」。

public struct QueryFilter: Equatable {
    /// 同一字段可有多谓词（全部 AND）；不同字段亦 AND。
    public var predicates: [QueryFieldKind: [FieldPredicate]] = [:]

    public init() {}

    public init(predicates: [QueryFieldKind: [FieldPredicate]]) {
        self.predicates = predicates
    }

    public var isActive: Bool { !predicates.isEmpty }

    /// 从 AST 字段节点提取（保持出现顺序，全 AND）。
    public static func from(_ nodes: [(field: QueryFieldKind, predicate: FieldPredicate)]) -> QueryFilter {
        var f = QueryFilter()
        for node in nodes {
            f.predicates[node.field, default: []].append(node.predicate)
        }
        return f
    }

    /// 书级判定（probe 语义同 SearchFilter.allows：positive filter 不匹配
    /// unknown）。bookTags 由调用方注入（favorites kind=book 的标签投影；
    /// 未收藏书 tags 为空集——恒不命中，帮助文案写明基准）。
    /// 正则档超时按该谓词不命中处理，不挂死。
    public func allows(book: IndexStore.BookRow, bookTags: Set<String>) -> Bool {
        for (field, preds) in predicates {
            for pred in preds {
                if !Self.evaluate(field: field, pred: pred, book: book, bookTags: bookTags) {
                    return false
                }
            }
        }
        return true
    }

    static func evaluate(field: QueryFieldKind, pred: FieldPredicate,
                         book: IndexStore.BookRow, bookTags: Set<String>) -> Bool {
        switch (field, pred) {
        case (.author, .equals(let v)):
            guard let a = book.author else { return false }
            return a.caseInsensitiveCompare(v) == .orderedSame
        case (.author, .contains(let v)):
            guard let a = book.author else { return false }
            return a.localizedCaseInsensitiveContains(v)
        case (.title, .equals(let v)):
            let t = book.title ?? book.fileName
            return t.caseInsensitiveCompare(v) == .orderedSame
        case (.title, .contains(let v)):
            let t = book.title ?? book.fileName
            return t.localizedCaseInsensitiveContains(v)
        case (.language, .equals(let v)):
            guard let l = book.language else { return false }
            return l.caseInsensitiveCompare(v) == .orderedSame
        case (.language, .contains(let v)):
            guard let l = book.language else { return false }
            return l.localizedCaseInsensitiveContains(v)
        case (.version, .equals(let v)):
            guard let ver = book.version else { return false }
            return ver.caseInsensitiveCompare(v) == .orderedSame
        case (.version, .contains(let v)):
            guard let ver = book.version else { return false }
            return ver.localizedCaseInsensitiveContains(v)
        case (.tag, .equals(let v)):
            return bookTags.contains { $0.caseInsensitiveCompare(v) == .orderedSame }
        case (.tag, .contains(let v)):
            return bookTags.contains { $0.localizedCaseInsensitiveContains(v) }
        case (.source, .equals(let v)):
            return SearchFilter.domain(ofPath: book.realPath).caseInsensitiveCompare(v) == .orderedSame
        case (.source, .contains(let v)):
            return SearchFilter.domain(ofPath: book.realPath).localizedCaseInsensitiveContains(v)
        case (_, .regex(let pattern)):
            // 字段值正则：取该字段的字符串值跑正则（1.0s 超时＝不命中）。
            let value: String?
            switch field {
            case .author: value = book.author
            case .title: value = book.title ?? book.fileName
            case .language: value = book.language
            case .version: value = book.version
            case .tag: value = bookTags.sorted().first   // 逐标签评估见下方重载
            case .source: value = SearchFilter.domain(ofPath: book.realPath)
            }
            guard let value else { return false }
            if field == .tag {
                return bookTags.contains { tag in
                    (try? Self.regexMatch(pattern: pattern, value: tag)) ?? false
                }
            }
            return (try? Self.regexMatch(pattern: pattern, value: value)) ?? false
        }
    }

    /// 字段值正则（书级；与页级同款子线程 1.0s 超时闸——灾难回溯的
    /// block 永不返回，回调查时闸不足为凭，子线程闸才是硬保证）。
    /// 大小写不敏感编译（正则在规范化文本上匹配，同页级基准）。
    static func regexMatch(pattern: String, value: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(location: 0, length: (value as NSString).length)
        final class Box: @unchecked Sendable { var found = false }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            regex.enumerateMatches(in: value, options: [.withTransparentBounds], range: range) { _, _, stop in
                if Date().timeIntervalSince(start) > querySyntaxRegexTimeout {
                    stop.pointee = true
                    return
                }
                box.found = true
                stop.pointee = true   // 只判存在性，首命中即停
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + querySyntaxRegexTimeout) == .timedOut {
            throw QuerySyntaxError.regexTimeout(pattern: pattern)
        }
        return box.found
    }
}

// MARK: - 页级求值（AST 节点 → 命中）

extension IndexStore {
    func allPageRowIDs() throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var out = Set<String>()
        let stmt = try db.prepare("SELECT rowid FROM pages;")
        while try stmt.step() { out.insert(String(stmt.int(0))) }
        return out
    }
}

enum QueryMatcher {
    /// 单节点在单页上的全部命中。正则超时抛 QuerySyntaxError.regexTimeout。
    /// regex 参数由调用方预编译传入（页循环外编译一次）；budget＝查询级
    /// 熔断预算（沿 SyntaxQueryPlan 传递）。
    static func matches(node: QueryNode, page: IndexStore.PageRow,
                        pageNormBytes: [UInt8], regex: NSRegularExpression? = nil,
                        budget: RegexBudget? = nil) throws -> [SearchHit.TermMatch] {
        switch node {
        case .term(let t), .phrase(let t):
            let prepared = SearchService.PreparedSearchTerm(term: t)
            return SearchService.utf8Matches(page: page, pageNormBytes: pageNormBytes, preparedTerms: [prepared])
        case .exactTerm(let t):
            return exactMatches(term: t, page: page, pageNormBytes: pageNormBytes)
        case .regex(let pattern):
            guard let regex else { return [] }   // 调用方负责编译传入
            return try regexMatches(regex: regex, pattern: pattern, page: page, budget: budget)
        case .field:
            return []   // 字段限定在书级过滤（QueryFilter），页级无词可匹配
        }
    }

    /// 精确档：规范化后词边界全词匹配。词边界定义：匹配位置前后相邻
    /// scalar 都不是「词字符」——词字符＝ASCII [0-9A-Za-z_] 或 CJK 意音
    /// 文字（U+3400–4DBF / 4E00–9FFF / –FAFF）。CJK 虽无空格分词，
    /// 但相邻汉字即同词：「权利」中的「权」不是独立词（词边界全词匹配的基准，测试断言固定）；空格/标点/串边界为词边界。
    /// UTF-8 偏移经既有码点边界函数换算成 scalar 判定，复用 firstRange 通道。
    static func exactMatches(term: String, page: IndexStore.PageRow, pageNormBytes: [UInt8]) -> [SearchHit.TermMatch] {
        let prepared = SearchService.PreparedSearchTerm(term: term)
        guard !prepared.utf8Bytes.isEmpty else { return [] }
        var out: [SearchHit.TermMatch] = []
        var from = 0
        while let s = SearchService.firstRange(pageNormBytes, prepared.utf8Bytes, from: from) {
            let e = s + prepared.utf8Bytes.count
            let prevIsWord = scalarAtUTF8Offset(page: page, pageNormBytes: pageNormBytes, offset: s - 1)
                .map(Self.isWordScalar) ?? false
            let nextIsWord = scalarAtUTF8Offset(page: page, pageNormBytes: pageNormBytes, offset: e)
                .map(Self.isWordScalar) ?? false
            if !prevIsWord && !nextIsWord {
                if let match = termMatch(prepared: prepared, page: page,
                                         pageNormBytes: pageNormBytes, s: s, e: e) {
                    out.append(match)
                }
            }
            from = e
        }
        return out
    }

    /// 取规范化文本中某 UTF-8 偏移处的首个 scalar（偏移先折到码点边界）；
    /// 越界返回 nil（串边界＝词边界）。
    static func scalarAtUTF8Offset(page: IndexStore.PageRow, pageNormBytes: [UInt8],
                                   offset: Int) -> Unicode.Scalar? {
        guard offset >= 0, offset < pageNormBytes.count else { return nil }
        let safe = SearchService.utf8CodePointBoundary(in: pageNormBytes, at: offset)
        let u8 = page.textNorm.utf8
        let u8Idx = u8.index(u8.startIndex, offsetBy: safe)
        guard let strIdx = String.Index(u8Idx, within: page.textNorm) else { return nil }
        return page.textNorm.unicodeScalars[strIdx]
    }

    /// 词字符判定（精确档词边界用）：ASCII 词字符＋CJK 意音文字。
    static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F: return true
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    /// 规范化命中区间 → 原文 TermMatch（与 utf8Matches 同款映射管线，抽出复用；
    /// utf8Matches 本体一个字节不动）。
    static func termMatch(prepared: SearchService.PreparedSearchTerm, page: IndexStore.PageRow,
                          pageNormBytes: [UInt8], s: Int, e: Int) -> SearchHit.TermMatch? {
        let u8View = page.textNorm.utf8
        let safeS = SearchService.utf8CodePointBoundary(in: pageNormBytes, at: s)
        let safeE = SearchService.utf8CodePointBoundary(in: pageNormBytes, at: e)
        let u8Start = u8View.index(u8View.startIndex, offsetBy: safeS)
        let u8End = u8View.index(u8View.startIndex, offsetBy: safeE)
        guard let strStart = String.Index(u8Start, within: page.textNorm),
              let strEnd = String.Index(u8End, within: page.textNorm),
              strStart < strEnd else { return nil }
        guard let originalRange = page.normalizedOriginalRange(normalizedRange: strStart..<strEnd) else { return nil }
        let originalCount = page.textOriginal.utf16.count
        guard originalRange.lowerBound >= 0, originalRange.upperBound <= originalCount else { return nil }
        let startIdx = String.Index(utf16Offset: originalRange.lowerBound, in: page.textOriginal)
        let endIdx = String.Index(utf16Offset: originalRange.upperBound, in: page.textOriginal)
        let displayTerm = String(page.textOriginal[startIdx..<endIdx])
        return SearchHit.TermMatch(term: prepared.term, displayTerm: displayTerm, originalUTF16Range: originalRange)
    }

    /// 正则档：在规范化文本上匹配（经既有映射回原文 range）＋ 1.0s 超时闸。
    static func regexMatches(regex: NSRegularExpression, pattern: String,
                             page: IndexStore.PageRow, budget: RegexBudget? = nil) throws -> [SearchHit.TermMatch] {
        final class ResultBox: @unchecked Sendable {
            var matches: [SearchHit.TermMatch] = []
        }
        let text = page.textNorm
        let full = NSRange(location: 0, length: (text as NSString).length)
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        // 熔断已触发：本页正则即时按超时处理（不排队等待；查询级预算）。
        if let budget, budget.tripped { throw QuerySyntaxError.regexTimeout(pattern: pattern) }
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            regex.enumerateMatches(in: text, options: [.withTransparentBounds], range: full) { m, _, stop in
                if Date().timeIntervalSince(start) > querySyntaxRegexTimeout {
                    stop.pointee = true   // 尽早放弃（辅助闸）
                    return
                }
                guard let m, let r = Range(m.range, in: text) else { return }
                guard let originalRange = page.normalizedOriginalRange(normalizedRange: r.lowerBound..<r.upperBound) else { return }
                let originalCount = page.textOriginal.utf16.count
                guard originalRange.lowerBound >= 0, originalRange.upperBound <= originalCount else { return }
                let startIdx = String.Index(utf16Offset: originalRange.lowerBound, in: page.textOriginal)
                let endIdx = String.Index(utf16Offset: originalRange.upperBound, in: page.textOriginal)
                let displayTerm = String(page.textOriginal[startIdx..<endIdx])
                box.matches.append(SearchHit.TermMatch(term: "re:\(pattern)", displayTerm: displayTerm,
                                                       originalUTF16Range: originalRange))
            }
            sem.signal()
        }
        let __tRegex = Date()
        let waited = sem.wait(timeout: .now() + querySyntaxRegexTimeout)
        budget?.charge(seconds: Date().timeIntervalSince(__tRegex))
        if waited == .timedOut {
            budget?.recordTimeout()
            throw QuerySyntaxError.regexTimeout(pattern: pattern)
        }
        return box.matches
    }
}


public enum TermRoute: Equatable {
    case cjkPath            // 含非 ASCII → 现行 bigram 全链（字节不动）
    case latinWordPath      // 纯字母数字非拼音 → pages_wfts 词级 MATCH
    case latinSubstringPath // 拼音词/含标点词/词路降级窗 → 快路子串
}

extension TermRoute {
    /// 路由名（诊断呈现；routedTerms 值域）。（拆分随迁：原
    /// SearchService.routeName static 函数，switch 体逐字不变；随类型改
    /// 实例方法——唯一调用点 searchDetailed 同步改 r.routeName。）
    func routeName() -> String {
        switch self {
        case .cjkPath: return "cjkPath"
        case .latinWordPath: return "latinWordPath"
        case .latinSubstringPath: return "latinSubstringPath"
        }
    }
}
