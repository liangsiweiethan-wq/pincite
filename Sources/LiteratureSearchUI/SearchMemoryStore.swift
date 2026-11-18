import Foundation
#if canImport(LiteratureCore)
import LiteratureCore
#endif

// MARK: - 一次性学习存储
//
// 「同查询第二次输入置顶上次选择」的存储面：记录用户在某查询下最后选中的
// (bookID, page)，下次同查询的结果列表头部显示「上次选择」锚点行。
//
// 边界纪律
//   · App 私有——不入 SharedHistoryStore（那是 AppGroup widget 共享面，
// 3-8 注明学习数据不得塞入）；本件落 Application Support 单文件。
//   · 习惯数据只服务「输入候选/历史补全/锚点行」层——不参与任何检索排序
// （SearchService 比较器零触碰，输出零漂移）。
//
// 归一化：键必须复用既有输出基线同一 `normalizeQuery`（LiteratureCore）——两套归一
// 化会造成「记下的锚点查不出来」的命中不一致。
//
// 存储：JSON 落 AppSupportPaths 目录（search-memory.json），atomic 写，
// NSLock 串行化；损坏 JSON 容错回空（学习数据可再生，宁空不崩）。
// 容量上限 128 条 LRU（新记录置顶，超限淘汰最旧）。

/// 一次选中记录（查询 → 书 + 物理页）。
public struct SearchSelectionAnchor: Codable, Equatable {
    public var bookID: String
    /// 1 起物理页（使用前由展示层校验 ≤ pageCount，失效即隐）。
    public var page: Int
    public var at: Date

    public init(bookID: String, page: Int, at: Date) {
        self.bookID = bookID
        self.page = page
        self.at = at
    }
}

/// 落盘条目（键＝normalizeQuery 后的查询串；数组首＝最近）。
private struct StoredEntry: Codable, Equatable {
    var key: String
    var anchor: SearchSelectionAnchor
}

private struct MemoryFile: Codable {
    var entries: [StoredEntry] = []
}

public final class SearchMemoryStore {
    /// 习惯学习总开关（设置页可关；缺省 true＝开）。所有读侧（锚点行/
    /// 补全候选）与记录侧共用此开关——关＝零记录零显示。
    public static let habitLearningDefaultsKey = "search.habitLearningEnabled"

    public static var habitLearningEnabled: Bool {
        if UserDefaults.standard.object(forKey: habitLearningDefaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: habitLearningDefaultsKey)
    }

    /// 容量上限。
    public static let maxEntries = 128

    /// 生产落点：AppSupport/LiteratureSearch/search-memory.json。
    public static func defaultFileURL() -> URL {
        AppSupportPaths.appDirectory("search-memory.json")
    }

    public let fileURL: URL
    private let lock = NSLock()
    private var entries: [StoredEntry]

    /// 注入 fileURL（合成测试走临时目录；缺省＝生产落点）。
    public init(fileURL: URL = SearchMemoryStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.entries = Self.load(fileURL: fileURL)
    }

    /// 记录一次选中（同查询覆盖旧锚点并置顶）。归一化后空查询/非法页码
    /// 一律忽略；开关关时不记录。
    public func recordSelection(query: String, bookID: String, page: Int, now: Date = Date()) {
        guard Self.habitLearningEnabled else { return }
        let key = normalizeQuery(query)
        guard !key.isEmpty, page >= 1, !bookID.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.key == key }
        entries.insert(StoredEntry(key: key,
                                   anchor: SearchSelectionAnchor(bookID: bookID, page: page, at: now)), at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        saveLocked()
    }

    /// 读锚点（同查询的「上次选择」）。归一化空查询/开关关一律 nil。
    public func anchor(for query: String) -> SearchSelectionAnchor? {
        guard Self.habitLearningEnabled else { return nil }
        let key = normalizeQuery(query)
        guard !key.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.key == key }?.anchor
    }

    /// 当前条数（设置/调试呈现）。
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// 清空（设置页维护动作；覆盖写空文件）。
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        entries = []
        saveLocked()
    }

    // MARK: 落盘（损坏容错回空；atomic 写）

    private static func load(fileURL: URL) -> [StoredEntry] {
        // 解码策略须与 saveLocked 的编码端（.secondsSince1970）对称——
        // 裸 JSONDecoder 缺省 .deferredToDate 按 2001 纪元读秒，落盘重载
        // 后 anchor.at 漂移约 +31 年。
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? decoder.decode(MemoryFile.self, from: data) else {
            return []
        }
        return file.entries.filter { !$0.key.isEmpty && $0.anchor.page >= 1 }
    }

    private func saveLocked() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(MemoryFile(entries: entries)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
