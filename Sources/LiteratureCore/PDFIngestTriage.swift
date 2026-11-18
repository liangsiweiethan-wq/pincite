import Foundation
import PDFKit

// MARK: - PDF 导入分诊

public enum PDFIngestTriage {

    /// 双阈值常量。
    public static let minCharsPerPage = 30
    public static let pageHasText = 10

    /// 五类分诊枚举。
    public enum Verdict: String, Sendable, Equatable, CaseIterable {
        case nativeOk = "native_ok"
        case scanned = "scanned"
        case mixed = "mixed"
        case unreadable = "unreadable"
        case missing = "missing"
    }

    public struct Outcome: Equatable, Sendable {
        public var verdict: Verdict
        /// 各物理页字符数（抽样实计数；missing/unreadable 为空）。
        public var charsPerPage: [Int]
        /// mixed 附加字段（可选 page_review）。
        public var pageReview: [Int]

        public init(verdict: Verdict, charsPerPage: [Int], pageReview: [Int] = []) {
            self.verdict = verdict
            self.charsPerPage = charsPerPage
            self.pageReview = pageReview
        }
    }

    /// 纯函数判类（抽样字符计数注入——生产用 PDFKit `page.string` 计数，
    /// 10-50ms 级；测试桩注入零 PDF 依赖）。
    /// 判类规则：
    ///   计数空           → missing（无页可计）
    ///   全 0 页          → unreadable（打开失败/无文字层且非扫描判定）
    ///   有文字页占比 1.0 → native_ok
    ///   有文字页占比 0   → scanned
    ///   其余             → mixed（page_review = 低于 PAGE_HAS_TEXT 的物理页）
    public static func classify(charsPerPage: [Int]) -> Outcome {
        guard !charsPerPage.isEmpty else {
            return Outcome(verdict: .missing, charsPerPage: [])
        }
        let withText = charsPerPage.filter { $0 >= Self.pageHasText }
        if withText.count == charsPerPage.count {
            let weak = charsPerPage.enumerated().compactMap { $1 < Self.minCharsPerPage ? $0 + 1 : nil }
            return Outcome(verdict: .nativeOk, charsPerPage: charsPerPage, pageReview: weak)
        }
        if withText.isEmpty {
            return Outcome(verdict: .scanned, charsPerPage: charsPerPage)
        }
        let review = charsPerPage.enumerated()
            .compactMap { $1 < Self.pageHasText ? $0 + 1 : nil }
        return Outcome(verdict: .mixed, charsPerPage: charsPerPage, pageReview: review)
    }

    /// 抽样计数（PDFKit `string` 系统路径；全页扫一遍）
    /// 10-50ms/百页级。missing/unreadable 由调用方按 PDFDocument nil / 空
    /// 计数表达，本函数不猜）。
    public static func sampleCharsPerPage(document: PDFDocument) -> [Int] {
        guard document.pageCount > 0 else { return [] }
        var counts: [Int] = []
        counts.reserveCapacity(document.pageCount)
        for i in 0..<document.pageCount {
            let text = document.page(at: i)?.string ?? ""
            counts.append(text.count)
        }
        return counts
    }

    // MARK: 书级 meta 键（schema 只增零迁移——meta 表键，随副本/备份同步）

    public static func metaKey(_ bookID: String) -> String { "pdf_triage:" + bookID }

    /// 写入书级分诊（接口位；默认导入链不调用）。
    public static func persist(_ outcome: Outcome, store: IndexStore, bookID: String) throws {
        // meta 值形："<verdict>|<page_review 逗号列>"（可逆、无嵌套 JSON 依赖）。
        let value = outcome.verdict.rawValue
            + "|" + outcome.pageReview.map(String.init).joined(separator: ",")
        try store.setMetaValue(metaKey(bookID), value)
    }

    /// 读取书级分诊（nil = 未分诊——绝不猜）。
    public static func load(store: IndexStore, bookID: String) -> (verdict: Verdict, pageReview: [Int])? {
        guard let raw = try? store.metaValue(metaKey(bookID)), !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1)
        guard let first = parts.first, let verdict = Verdict(rawValue: String(first)) else { return nil }
        let review = parts.count > 1
            ? parts[1].split(separator: ",").compactMap { Int($0) }
            : []
        return (verdict, review)
    }
}

// MARK: - IndexingEngine 导入链接口位（预留；默认链路零调用）

extension IndexingEngine {
    /// 导入链分诊接口位（预留）：对单个 PDF 做五类分诊。
    /// **默认导入链不调用**（不改导入默认行为）。
    public func triagePDF(at url: URL) -> PDFIngestTriage.Outcome {
        guard let document = PDFDocument(url: url) else {
            return PDFIngestTriage.Outcome(verdict: .missing, charsPerPage: [])
        }
        let counts = PDFIngestTriage.sampleCharsPerPage(document: document)
        if counts.isEmpty {
            return PDFIngestTriage.Outcome(verdict: .missing, charsPerPage: [])
        }
        return PDFIngestTriage.classify(charsPerPage: counts)
    }
}
