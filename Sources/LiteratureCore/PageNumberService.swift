import Foundation

// MARK: - 稳定页码语义：页码基准与统一取页服务（镜：KOReader stable

/// 页码基准。存储基准恒为 physical；pageLabel/printed 仅作显示与引注换算。
public enum PageBasis: String, CaseIterable, Sendable {
    case physical
    case pageLabel
    case printed
}

/// 统一取页服务：printed 页码两路合成（page_map 表 > pages.printed_page 列）。
/// 查询闭包注入（合成测试桩可注入，绝不触真实库）；生产组装见
/// `PageNumberService.forStore`。
public struct PageNumberService: Sendable {
    public let pageMapLookup: @Sendable (_ bookID: String, _ physical: Int) -> Int?
    public let pagesColumnLookup: @Sendable (_ bookID: String, _ physical: Int) -> Int?

    public init(pageMapLookup: @escaping @Sendable (String, Int) -> Int?,
                pagesColumnLookup: @escaping @Sendable (String, Int) -> Int?) {
        self.pageMapLookup = pageMapLookup
        self.pagesColumnLookup = pagesColumnLookup
    }

    /// printed 页码：page_map 显式声明优先，其次 pages.printed_page 列；
    /// 都无 → nil（未知，绝不猜）。
    public func printedPage(bookID: String, physical: Int) -> Int? {
        if let mapped = pageMapLookup(bookID, physical) { return mapped }
        return pagesColumnLookup(bookID, physical)
    }

    /// 生产组装：两路查询绑定到一个已打开的 IndexStore。
    public static func forStore(_ store: IndexStore) -> PageNumberService {
        PageNumberService(
            pageMapLookup: { bookID, physical in
                try? store.pageMapPrinted(bookID: bookID, physical: physical)
            },
            pagesColumnLookup: { bookID, physical in
                try? store.printedPageColumn(bookID: bookID, physical: physical)
            })
    }
}

// MARK: - sidecar 解析（声明制导入；与 import-meta 同为用户显式动作）

/// 导入报告：accepted/rejected 计数与原因逐行可溯（审计记录形态）。
public struct PageMapImportReport: Equatable, Sendable {
    public struct Reject: Equatable, Sendable {
        public let line: Int
        public let reason: String
    }

    public var acceptedRows: Int
    public var offsetBooks: [String]
    public var unmatchedBooks: [String]   // 未匹配 fileName → 整书跳过（不猜）
    public var rejected: [Reject]

    public init(acceptedRows: Int = 0, offsetBooks: [String] = [],
                unmatchedBooks: [String] = [], rejected: [Reject] = []) {
        self.acceptedRows = acceptedRows
        self.offsetBooks = offsetBooks
        self.unmatchedBooks = unmatchedBooks
        self.rejected = rejected
    }
}

/// 一本待导入书的解析产物：逐页 (physical, printed) 对 + 来源版次串。
public struct PageMapBookEntries: Equatable, Sendable {
    public var bookID: String
    public var fileName: String
    public var sourceEdition: String
    /// (physical, printed) 升序；offset 模式已在解析期展开为逐页对。
    public var pairs: [(physical: Int, printed: Int)]

    public init(bookID: String, fileName: String, sourceEdition: String,
                pairs: [(physical: Int, printed: Int)]) {
        self.bookID = bookID
        self.fileName = fileName
        self.sourceEdition = sourceEdition
        self.pairs = pairs
    }

    public static func == (a: PageMapBookEntries, b: PageMapBookEntries) -> Bool {
        a.bookID == b.bookID && a.fileName == b.fileName
            && a.sourceEdition == b.sourceEdition
            && a.pairs.count == b.pairs.count
            && zip(a.pairs, b.pairs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

public enum PageMapSidecar {
    /// 解析 sidecar CSV 并校验。两种来路（docs/PAGE-BASIS.md）：
    ///   显式对：fileName,physical,printed[,source_edition]（默认/无表头形态）
    ///   offset：fileName,offset[,source_edition]（printed = physical + offset，
    ///           解析期按该书 pageCount 展开为逐页对；printed ≤ 0 的前置页
    public static func parse(_ data: Data,
                             books: [String: (bookID: String, pageCount: Int)]) throws
    -> (entries: [PageMapBookEntries], report: PageMapImportReport) {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16) else {
            throw PageMapSidecarError("sidecar is not valid UTF-8/UTF-16 text")
        }

        var report = PageMapImportReport()
        var entries: [PageMapBookEntries] = []
        var seenPairs: Set<String> = []   // "bookID|physical" 防同书同页重复行

        enum Mode { case undetermined, explicit, offset }
        var mode: Mode = .undetermined

        var iterator = csvRows(text).makeIterator()
        var lineNumber = 0
        rowLoop: while true {
            let row = iterator.next()
            guard let fields = row else { break }
            lineNumber += 1
            let trimmed = fields.map { $0.trimmingCharacters(in: .whitespaces) }
            if trimmed.allSatisfy({ $0.isEmpty }) { continue rowLoop }

            if mode == .undetermined {
                let joined = trimmed.map { $0.lowercased() }.joined(separator: ",")
                if looksLikeHeader(trimmed) {
                    mode = joined.contains("offset") ? .offset : .explicit
                    continue rowLoop
                }
                // 无表头：一律显式对（2 列行将在显式分支按缺列拒收）。
                mode = .explicit
            }

            if trimmed.count < 2 {
                report.rejected.append(.init(line: lineNumber,
                                             reason: "缺列（需 ≥2 列）"))
                continue rowLoop
            }

            let fileName = trimmed[0]
            guard let book = books[fileName] else {
                if !report.unmatchedBooks.contains(fileName) {
                    report.unmatchedBooks.append(fileName)
                }
                continue rowLoop
            }
            guard book.pageCount > 0 else {
                report.rejected.append(.init(line: lineNumber,
                                             reason: "\(fileName) 无有效页数，拒绝导入"))
                continue rowLoop
            }

            let edition = trimmed.count >= 4 ? trimmed[3] : ""

            switch mode {
            case .offset:
                guard let offset = Int(trimmed[1]) else {
                    report.rejected.append(.init(line: lineNumber,
                                                 reason: "offset 非整数：\(trimmed[1])"))
                    continue rowLoop
                }
                var pairs: [(Int, Int)] = []
                var droppedPrefixPages = 0
                for physical in 1...book.pageCount {
                    let printed = physical + offset
                    guard printed > 0 else {
                        droppedPrefixPages += 1
                        continue
                    }
                    pairs.append((physical, printed))
                }
                if droppedPrefixPages > 0 {
                    report.rejected.append(.init(
                        line: lineNumber,
                        reason: "\(fileName) 前置 \(droppedPrefixPages) 页换算 printed ≤ 0（前置罗马页等），已拒收"))
                }
                let key = "\(book.bookID)|offset"
                guard !seenPairs.contains(key) else {
                    report.rejected.append(.init(line: lineNumber,
                                                 reason: "\(fileName) 已有 offset 声明，同书第二条 offset 行拒收"))
                    continue rowLoop
                }
                seenPairs.insert(key)
                report.offsetBooks.append(fileName)
                report.acceptedRows += pairs.count
                entries.append(PageMapBookEntries(bookID: book.bookID, fileName: fileName,
                                                  sourceEdition: edition,
                                                  pairs: pairs.map { ($0.0, $0.1) }))

            case .explicit, .undetermined:
                guard trimmed.count >= 3 else {
                    report.rejected.append(.init(line: lineNumber,
                                                 reason: "显式对需 ≥3 列（fileName,physical,printed[,source_edition]）"))
                    continue rowLoop
                }
                guard let physical = Int(trimmed[1]) else {
                    report.rejected.append(.init(line: lineNumber,
                                                 reason: "physical 非整数：\(trimmed[1])"))
                    continue rowLoop
                }
                guard let printed = Int(trimmed[2]) else {
                    report.rejected.append(.init(line: lineNumber,
                                                 reason: "printed 非整数：\(trimmed[2])"))
                    continue rowLoop
                }
                guard printed >= 0 else {
                    report.rejected.append(.init(line: lineNumber,
                                                 reason: "printed 为负数：\(printed)"))
                    continue rowLoop
                }
                guard physical >= 1, physical <= book.pageCount else {
                    report.rejected.append(.init(
                        line: lineNumber,
                        reason: "physical 越界：\(physical) ∉ 1...\(book.pageCount)"))
                    continue rowLoop
                }
                let key = "\(book.bookID)|\(physical)"
                guard !seenPairs.contains(key) else {
                    report.rejected.append(.init(line: lineNumber,
                                                 reason: "\(fileName) 物理页 \(physical) 重复行"))
                    continue rowLoop
                }
                seenPairs.insert(key)
                report.acceptedRows += 1
                if let idx = entries.firstIndex(where: { $0.bookID == book.bookID }) {
                    entries[idx].pairs.append((physical, printed))
                } else {
                    entries.append(PageMapBookEntries(bookID: book.bookID, fileName: fileName,
                                                      sourceEdition: edition,
                                                      pairs: [(physical, printed)]))
                }
            }
        }
        for idx in entries.indices where entries[idx].pairs.count > 1 {
            entries[idx].pairs.sort { $0.0 < $1.0 }
        }
        return (entries, report)
    }

    /// 表头嗅探：首字段像 fileName 列名（fileName/file/name）或第二列像
    /// physical/offset 列名。仅用于无值行判定，绝不把数据行当表头丢弃。
    static func looksLikeHeader(_ fields: [String]) -> Bool {
        let lowered = fields.map { $0.lowercased() }
        if lowered.first.map({ ["filename", "file", "name"].contains($0) }) == true {
            return true
        }
        if lowered.count >= 2,
           ["physical", "offset", "page"].contains(lowered[1]) {
            return true
        }
        return false
    }

    /// 最小 CSV 行解析：支持双引号包裹（内含逗号/转义引号）；无引号按逗号切。
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        for line in text.components(separatedBy: .newlines) {
            guard !line.isEmpty else { continue }
            var fields: [String] = []
            var current = ""
            var inQuotes = false
            var iterator = line.makeIterator()
            var pending: Character? = iterator.next()
            while let ch = pending {
                if inQuotes {
                    if ch == "\"" {
                        let next = iterator.next()
                        if next == "\"" { current.append("\"") } else {
                            inQuotes = false
                            pending = next
                            continue
                        }
                    } else {
                        current.append(ch)
                    }
                } else if ch == "\"" {
                    inQuotes = true
                } else if ch == "," {
                    fields.append(current)
                    current = ""
                } else {
                    current.append(ch)
                }
                pending = iterator.next()
            }
            fields.append(current)
            rows.append(fields)
        }
        return rows
    }
}

/// sidecar 级错误（整文件不可解析时抛出；行级问题走报告不抛）。
public struct PageMapSidecarError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
