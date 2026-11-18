import Foundation

// MARK: - verify 相页文本源缝合层
//
// 目标：SearchService 三路 verify（常规/词路/语法）的页全量物化统一走
// `PageTextSource` 抽象——缺省＝`SQLitePageTextSource` 直通 `IndexStore.
// pages(rowIDs:)`，**逐字节同源＝现路径**（回归零漂移的第一保证）；侧车
// 第二实现挂同一协议，为抽取缓存（ExtractionTextCache）提供检索读侧通道。
//
// 命中条件＝写时「已对齐」标志（构建侧校验缓存与 SQLite 行逐字节一致后
// 落标志，运行时只读标志）。当前 ExtractionTextCache 为**抽取时**写侧
// （PDFTextExtractor.extract 缓存外壳，先于 SQLite 页行事务），格式无
// 「已对齐」标志位。故本实现的命中门＝键内三元校验（sha/缓存格式/归一化
// 版本，缓存件自带）＋轻行元数据交叉核对（页号/label/printed_page）＋
// text_norm 逐字相等（lightPages 本就带 text_norm，零额外 I/O）＋OCR 页
// 一律不接（OCR 页文本属配对 OCR 文件，缓存键是原件指纹）——并**默认不
// 激活**：SearchServiceConfig.textSource 缺省 nil＝SQLite 直通＝现行为；
// 侧车源仅经配置显式注入（调试/实验通道）才生效。若日后缓存补「已对齐」
// 标志，把 SidecarPageTextSource 的命中门升级为标志判定即可（缝已收在本文件）。
//
// 等价性论证（命中态）：同源推导——SQLite 页行与缓存条目同出自同一次
// PDFExtractionResult（同 sha256＋同归一化版本 ⇒ 同抽取输出）；命中门的
// 元数据/text_norm 核对是其必要条件检查。默认直通态则与现路径逐字节相同。
//
// 不变式：物化/匹配/排序逻辑零改动——本层只替换「页行从哪来」，utf8Matches/
// wordMatches/QueryMatcher/snippet/round-robin 全在缝合点下游，输入不变则
// 输出不变。

/// verify 相页文本源抽象。签名对齐 verify 相唯一取页口
/// `IndexStore.pages(rowIDs:)`——不引入新的取页方式。
/// 输出契约与 `IndexStore.pages(rowIDs:)` 同构：按输入 rowID 顺序输出
/// 找到的页行（缺失行跳过、重复 rowID 去重保首序）。
public protocol PageTextSource {
    func pages(rowIDs: [String]) throws -> [IndexStore.PageRow]
}

/// 默认实现：直通 `IndexStore.pages(rowIDs:)`，字节零差异。
public struct SQLitePageTextSource: PageTextSource {
    let store: IndexStore

    public init(store: IndexStore) {
        self.store = store
    }

    public func pages(rowIDs: [String]) throws -> [IndexStore.PageRow] {
        try store.pages(rowIDs: rowIDs)
    }
}

/// 侧车第二实现：`ExtractionTextCache`（按源文件 sha256 键）支撑的
/// 页文本源。命中门见文件头注；任何一门不过（未命中/哈希不符/版本不符/
/// 元数据不符/OCR 页）→ 该行回落 SQLite 现路径（四态回落矩阵）。
/// 输出顺序＝输入 rowID 序（与 IndexStore.pages 同构）——命中行与回落行
/// 按输入序归并，下游配对（pairStage2Rows）与切片语义不受影响。
public struct SidecarPageTextSource: PageTextSource {
    let store: IndexStore
    let cache: ExtractionTextCache

    public init(store: IndexStore, cache: ExtractionTextCache) {
        self.store = store
        self.cache = cache
    }

    public func pages(rowIDs: [String]) throws -> [IndexStore.PageRow] {
        guard !rowIDs.isEmpty else { return [] }
        // 轻行（含 text_norm）一次取齐：命中门核对材料＋rowID→(书,页) 解析。
        let lightRows = try store.lightPages(rowIDs: rowIDs)
        guard !lightRows.isEmpty else { return [] }

        var byRowID: [Int64: IndexStore.PageRow] = [:]
        byRowID.reserveCapacity(lightRows.count)
        var cacheByBook: [String: PDFExtractionResult?] = [:]   // nil = 查过未命中
        var pairingCache: [String: Set<Int>] = [:]                    // bookID → OCR 页集

        for light in lightRows {
            // OCR 源页不接：其页文本来自配对 OCR 文件，缓存键是原件指纹。
            let ocrPages: Set<Int>
            if let cached = pairingCache[light.bookID] {
                ocrPages = cached
            } else {
                let info = try? store.ocrPairing(bookID: light.bookID)   // try? 扁平化 → OCRPairingInfo?
                ocrPages = info?.ocrSourcedPages ?? []
                pairingCache[light.bookID] = ocrPages
            }
            guard !ocrPages.contains(light.pageNumber) else { continue }

            // 书行取指纹（缓存键＝源文件 sha256）。
            guard let book = try? store.book(byID: light.bookID) else { continue }
            let entry: PDFExtractionResult?
            if let cached = cacheByBook[light.bookID] {
                entry = cached
            } else {
                let fetched = cache.result(fileSHA256: book.fingerprint)
                cacheByBook[light.bookID] = fetched
                entry = fetched
            }
            guard let entry else { continue }   // 未命中/键非法/半件/损坏/版本不符 → 回落
            // 物理页定位：缓存页条目按 physicalPage 恰一条（extractor 契约）。
            guard let pageEntry = entry.pages.first(where: { $0.physicalPage == light.pageNumber }) else { continue }
            // 元数据交叉核对（必要条件门）：页号/label/printed_page 与库行一致。
            guard pageEntry.label == light.label, pageEntry.printedPage == light.printedPage else { continue }
            // text_norm 逐字相等（匹配域一致性门；lightPages 本就带，零额外 I/O）。
            guard pageEntry.normalized.text == light.textNorm else { continue }

            byRowID[light.rowID] = IndexStore.PageRow(
                bookID: light.bookID, pageNumber: light.pageNumber,
                label: light.label, printedPage: light.printedPage,
                textOriginal: pageEntry.text, textNorm: light.textNorm,
                normStarts: pageEntry.normalized.starts, normEnds: pageEntry.normalized.ends)
        }
        // 注意：byRowID 为空（缓存全未命中＝四态回落矩阵的 miss/哈希不符/
        // 版本不符全回落态）**不得**在此早退——回落实取与归并必须照走，
        // 否则全回落态返回空集违反「输出与 store.pages 同构」契约。

        // 回落：未接行按原口取 SQLite（一次批量），再按输入序归并输出。
        let fallbackIDs = rowIDs.filter { raw in
            guard let id = Int64(raw) else { return true }   // 非数字 rowID 原样回落
            return byRowID[id] == nil
        }
        let fallbackRows = try store.pages(rowIDs: fallbackIDs)
        var fallbackByID: [String: IndexStore.PageRow] = [:]
        for row in fallbackRows {
            // (bookID, pageNumber) 在库内唯一（pages 主键），rowID 非负可回查；
            // store.pages 输出无 rowid 字段，按序与 fallbackIDs 对位不可靠——
            // 以 (bookID,pageNumber) 建键精确归并（与 pairStage2Rows 同法）。
            fallbackByID["\(row.bookID)\u{1F}#\(row.pageNumber)"] = row
        }
        var lightByID: [Int64: IndexStore.LightPageRow] = [:]
        for light in lightRows { lightByID[light.rowID] = light }

        var out: [IndexStore.PageRow] = []
        out.reserveCapacity(rowIDs.count)
        var seen = Set<Int64>()
        for raw in rowIDs {
            guard let id = Int64(raw), seen.insert(id).inserted else { continue }
            if let served = byRowID[id] {
                out.append(served)
            } else if let light = lightByID[id],
                      let row = fallbackByID["\(light.bookID)\u{1F}#\(light.pageNumber)"] {
                out.append(row)
            }
        }
        return out
    }
}

/// SearchService 构造配置（以配置结构体注入，避免构造点扩散）。
/// 缺省值＝现行为（textSource nil → SQLite 直通）。
public struct SearchServiceConfig {
    /// verify 相页文本源。nil＝`store.pages(rowIDs:)` 直通（现路径，默认）。
    var textSource: PageTextSource?

    public init(textSource: PageTextSource? = nil) {
        self.textSource = textSource
    }

    /// SQLite 直通源（显式取用口；与缺省 nil 等价，测试/组装便利）。
    public static func sqlite(store: IndexStore) -> SearchServiceConfig {
        SearchServiceConfig(textSource: SQLitePageTextSource(store: store))
    }

    /// 侧车源（显式注入才生效；命中门与回落矩阵见 SidecarPageTextSource）。
    public static func sidecar(store: IndexStore, cache: ExtractionTextCache) -> SearchServiceConfig {
        SearchServiceConfig(textSource: SidecarPageTextSource(store: store, cache: cache))
    }
}

// MARK: - 高亮定位侧车缝合（App 侧 PDFDetailView 调用）

/// 高亮定位的侧车文本源。共享一个只读 `ExtractionTextCache` 实例（生产目录
/// AppSupportPaths.textCacheDirectory；读侧 fail-open，写侧在索引路径）。
/// `alignedPageText` 的命中门：显式开启（调用方闸）＋缓存三元校验命中＋
/// 页条目存在＋与 PDFKit 现抽文本同长（必要条件防错位闸；缓存补「已对齐」
/// 标志后可升级为标志判定）。`page.selection(for:)` 恒对真实 PDFKit
/// 页面求值——坐标永不出自缓存文本。
public final class PDFHighlightTextSource {
    /// 共享实例（懒建；App 进程内单例，读多写无）。
    public static let shared = PDFHighlightTextSource()

    let cache: ExtractionTextCache

    /// 生产实例（AppSupportPaths 生产目录）。
    public convenience init() {
        let dir = AppSupportPaths.textCacheDirectory(under: AppSupportPaths.baseDirectory())
        self.init(cache: ExtractionTextCache(directory: dir))
    }

    /// 注入实例（合成测试专用：临时目录，绝不触真实 Application Support）。
    public init(cache: ExtractionTextCache) {
        self.cache = cache
    }

    /// 侧车命中等价文本；任何一门不过返回 nil（调用方回落 PDFKit 现抽）。
    /// `live`＝PDFKit `page.string`（现抽文本；nil 或异长即不接）。
    public func alignedPageText(fingerprint: String, pageNumber: Int, live: String?) -> String? {
        guard let live, !live.isEmpty else { return nil }
        guard let entry = cache.result(fileSHA256: fingerprint),
              let pageEntry = entry.pages.first(where: { $0.physicalPage == pageNumber }) else { return nil }
        guard pageEntry.text.utf16.count == live.utf16.count else { return nil }
        return pageEntry.text
    }
}
