import Foundation
// macOS Xcode builds link LiteratureCore as a library; iOS/watch app targets
// compile the core sources directly into the same target (widget pattern), so
// the import exists only when the module does.（与 HitRouter.swift:5
// 同形的最小防护；条件编译白名单说明扩展本文件。）
#if canImport(LiteratureCore)
import LiteratureCore
#endif

/// 同书重开恢复上次页码与缩放。per-book 字典 bookID →
/// ReadingPosition，持久化到 Application Support 下一个小 JSON 文件
/// （reader-preferences.json，原子写）；旧版 UserDefaults 存档只读回退，
/// 命中后一次性迁移写穿（不删旧档）。坏数据 fail-closed 视为无存档。
/// 纯 Foundation，供 app 层与合成测试共用。
public struct ReadingPosition: Equatable, Codable {
    /// 物理页（1 起）。
    public var page: Int
    /// PDFView.scaleFactor（> 0 才有意义）。
    public var scale: Double
    /// 双页对开（PDFView .twoUpContinuous）；新增——旧档缺该字段时
    /// 按单页（false）解码，历史偏好不丢。
    public var twoPage: Bool
    /// 锁定高亮锚点页（1 起物理页；nil = 未锁定）。旧档缺该字段时解码
    /// 为 nil，向后兼容。
    public var anchorPage: Int?

    enum CodingKeys: String, CodingKey {
        case page, scale, twoPage, anchorPage
    }

    public init(page: Int, scale: Double, twoPage: Bool = false, anchorPage: Int? = nil) {
        self.page = page
        self.scale = scale
        self.twoPage = twoPage
        self.anchorPage = anchorPage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = try container.decode(Int.self, forKey: .page)
        scale = try container.decode(Double.self, forKey: .scale)
        twoPage = try container.decodeIfPresent(Bool.self, forKey: .twoPage) ?? false
        anchorPage = try container.decodeIfPresent(Int.self, forKey: .anchorPage)
    }
}

public final class ReadingPositionStore {
    /// 存储目录（缺目录即建）；测试注入临时目录，绝不写真实 Application Support。
    private let directory: URL
    /// 目标 JSON 文件（directory 下固定文件名）。
    private let fileURL: URL
    /// 旧版 UserDefaults 回退源（只读；命中后迁移写穿文件，不删旧档）。
    private let legacyDefaults: UserDefaults
    private let legacyKey: String
    /// 内存镜像，读多写少；写入即持久化。
    private var cache: [String: ReadingPosition]?
    /// legacy 回退只尝试一次（无论命中与否）。
    private var didTryLegacy = false

    public init(directory: URL = ReadingPositionStore.defaultDirectory(),
                legacyDefaults: UserDefaults = .standard,
                legacyKey: String = "readingPositions") {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("reader-preferences.json", isDirectory: false)
        self.legacyDefaults = legacyDefaults
        self.legacyKey = legacyKey
    }

    /// 生产默认：~/Library/Application Support/LiteratureSearch/。
    /// 根目录推导收拢至 AppSupportPaths（落点不变）。
    /// 仅新建本类自己的 JSON 文件，不触碰目录内其他（索引库等）内容。
    public static func defaultDirectory() -> URL {
        AppSupportPaths.appDirectory()
    }

    public func position(for bookID: String) -> ReadingPosition? {
        assert(Thread.isMainThread, "ReadingPositionStore.position 须在主线程调用")
        return load()[bookID]
    }

    /// 仅接受 page ≥ 1、scale > 0 的合法值；非法输入**整体拒写**（fail-closed，
    /// 不落半条档、不保留旧档部分字段——语义由 saveRejectsInvalidInput 测试锁定）。
    public func save(page: Int, scale: Double, twoPage: Bool? = nil, for bookID: String) {
        assert(Thread.isMainThread, "ReadingPositionStore.save 须在主线程调用")
        guard page >= 1, scale > 0 else { return }
        var dict = load()
        let existing = dict[bookID]
        let keptTwoPage = twoPage ?? existing?.twoPage ?? false
        // 翻页/缩放写入不得清掉已锁定锚点（锚点只经 save(anchorPage:) 变更）。
        dict[bookID] = ReadingPosition(page: page, scale: scale, twoPage: keptTwoPage,
                                       anchorPage: existing?.anchorPage)
        persist(dict)
    }

    /// 锁定高亮锚点：仅改 anchorPage，页/缩放/双页偏好原样保留。nil =
    /// 清除锚点；< 1 的非法页忽略（fail-closed）。无既有档时以占位档
    /// （page 1 / scale 1.0 / 单页）建仓，锚点语义独立成立。
    public func save(anchorPage: Int?, for bookID: String) {
        assert(Thread.isMainThread, "ReadingPositionStore.save(anchorPage:) 须在主线程调用")
        guard anchorPage == nil || anchorPage! >= 1 else { return }
        var dict = load()
        let existing = dict[bookID]
        dict[bookID] = ReadingPosition(page: existing?.page ?? 1,
                                       scale: existing?.scale ?? 1.0,
                                       twoPage: existing?.twoPage ?? false,
                                       anchorPage: anchorPage)
        persist(dict)
    }

    // MARK: - 私有：装载与原子写

    private func load() -> [String: ReadingPosition] {
        if let cache { return cache }
        if let onDisk = decode(fileURL) {
            cache = onDisk
            didTryLegacy = true
            return onDisk
        }
        // 文件缺失/坏档：回退旧版 UserDefaults 存档（旧档无 twoPage 字段，
        // ReadingPosition 的 decodeIfPresent 按单页兼容解码）。
        if !didTryLegacy {
            didTryLegacy = true
            if let legacy = decode(legacyDefaults.data(forKey: legacyKey)) {
                cache = legacy
                persist(legacy)
                return legacy
            }
        }
        cache = [:]
        return [:]
    }

    private func decode(_ url: URL) -> [String: ReadingPosition]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    private func decode(_ data: Data?) -> [String: ReadingPosition]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: ReadingPosition].self, from: data)
    }

    /// 原子写（write .atomic 内部临时文件 + rename）；失败不静默——stderr
    /// 记录，内存镜像仍生效，下次写入重试。
    private func persist(_ dict: [String: ReadingPosition]) {
        cache = dict
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(dict)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            fputs("ReadingPositionStore: 持久化失败 \(error)\n", stderr)
        }
    }
}
