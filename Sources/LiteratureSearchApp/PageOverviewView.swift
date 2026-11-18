import SwiftUI
import AppKit
import PDFKit
import LiteratureCore
import LiteratureSearchUI

/// 概览缩略渲染参数（设置页可调；UserDefaults 持久化；**每项默认＝现行为**）。硬封顶纪律：缓存条数/字节上限只提供档位
/// 选择（0＝不限＝现行为，无自由数值输入），改大吃内存的风险由档位表结算。
/// 说明：sioyek 的 prerendered_page_count/should_draw_unrendered_pages 在
/// PDFKit 无直接对应物——本实现的等价近似＝可选预取半径＋既有懒渲染占位
/// （占位已存在，不动）。
enum ThumbnailRenderParams {
    static let cacheCountLimitKey = "overview.thumbCacheCountLimit"
    static let cacheCostLimitMBKey = "overview.thumbCacheCostLimitMB"
    static let prefetchRadiusKey = "overview.prefetchRadius"
    static let pixelTierKey = "overview.thumbPixelTier"

    /// 缓存条数上限（0＝不设限＝现行为）。
    static var cacheCountLimit: Int {
        let v = UserDefaults.standard.integer(forKey: cacheCountLimitKey)
        return v > 0 ? v : 0
    }

    /// 缓存字节上限（MB；0＝不设限＝现行为）。
    static var cacheCostLimitMB: Int {
        let v = UserDefaults.standard.integer(forKey: cacheCostLimitMBKey)
        return v > 0 ? v : 0
    }

    /// 预取半径（页；0＝关＝现行为；档位硬封顶 3）。
    static var prefetchRadius: Int {
        min(max(UserDefaults.standard.integer(forKey: prefetchRadiusKey), 0), 3)
    }

    /// 像素档：0＝标准 320×420（默认＝现值）；1＝高清 480×630。
    static var pixelTier: Int {
        UserDefaults.standard.integer(forKey: pixelTierKey) == 1 ? 1 : 0
    }

    /// 当前档位的缩略图像素尺寸。
    static var thumbPixelSize: CGSize {
        pixelTier == 1 ? CGSize(width: 480, height: 630) : CGSize(width: 320, height: 420)
    }

    /// 单页缩略图内存估算（RGBA 4 字节/像素；调试面板「估算」基准）。
    static var perThumbnailBytes: Int {
        Int(thumbPixelSize.width * thumbPixelSize.height * 4)
    }
}

/// 概览弹窗（Sioyek Thumbnail Grid）：当前 PDF 的 3×N 页面缩略九宫格。
/// 懒生成（LazyVGrid 只建可视 cell + NSCache 复用已生成缩略图），点击任一
/// 缩略跳该页（经阅读器桥 jumpHandler，自动入历史栈）并关闭浮窗；当前页
/// 高亮描边；ESC（本地监视器）/点击外部关闭。cell 只在可视期间持有
/// PDFPage，弹窗关闭即全部释放——不泄漏 PDFView/document。
/// 缓存上限/预取半径/像素档可参数化（默认全＝现行为，见
/// ThumbnailRenderParams）。
struct PageOverviewView: View {
    @ObservedObject var readerState: PDFReaderState
    @Binding var isPresented: Bool
    /// 跳页回调（详情栏注入：关弹窗 + readerState.jump(to:)）。
    let onSelect: (Int) -> Void
    /// 已翻到的页集合（1 起物理页；详情栏注入快照——本视图保持
    /// 无 store 依赖，:11-27 结构不变；徽标判定走纯函数 isPageViewed 供
    /// 合成测试）。足迹语义＝「翻到即记」（viewed≠精读，图例如实命名）。
    var footprints: Set<Int> = []
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    @State private var escMonitor: Any?
    /// 缩略图缓存：0 起页索引 → NSImage（弹窗关闭随视图释放）。上限接设置
    /// （默认 0＝不设限＝现行为；开销按生成时登记的 RGBA 估算）。
    private let cache = NSCache<NSNumber, NSImage>()

    /// 徽标判定走 Core 纯函数 PageFootprintBadge.isViewed（合成测试直测真实现）。
    private static let columns = [
        GridItem(.fixed(160), spacing: DS.Spacing.sm),
        GridItem(.fixed(160), spacing: DS.Spacing.sm),
        GridItem(.fixed(160), spacing: DS.Spacing.sm),
    ]

    var body: some View {
        let theme = DS.Theme.storage(dsTheme)
        return VStack(spacing: DS.Spacing.sm) {
            Text(L10n.overviewTitle)
                .font(DS.Font.displaySection)
                .foregroundStyle(DS.Color.ink(theme, scheme))
            // 足迹图例（如实命名：圆点＝已翻到的页，不称「已精读」）。
            Text(L10n.overviewFootprintLegend)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            if let document = readerState.pdfView?.document, document.pageCount > 0 {
                ScrollView {
                    LazyVGrid(columns: Self.columns, spacing: DS.Spacing.sm) {
                        ForEach(0..<document.pageCount, id: \.self) { index in
                            if let page = document.page(at: index) {
                                OverviewCell(
                                    pageIndex: index,
                                    page: page,
                                    pixelSize: ThumbnailRenderParams.thumbPixelSize,
                                    isCurrent: readerState.currentPage == index + 1,
                                    isAnchored: readerState.anchorPage == index + 1,
                                    isViewed: PageFootprintBadge.isViewed(index + 1,
                                                                          footprints: footprints),
                                    onSelect: onSelect,
                                    cache: cache)
                            }
                        }
                    }
                    .padding(DS.Spacing.xs)
                }
            } else {
                Spacer()
                Text(L10n.detailPlaceholder)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                Spacer()
            }
        }
        .padding(DS.Spacing.md)
        .frame(width: 560, height: 480)
        .background(DS.Color.paper(theme, scheme))
        .onAppear {
            applyRenderParams()
            prefetchAroundCurrentPage()
            installESCMonitor()
        }
        // 预取半径 > 0 时随当前页移动预生成邻页缩略（0＝关＝现行为）。
        .onChange(of: readerState.currentPage) { _ in prefetchAroundCurrentPage() }
        .onDisappear { removeESCMonitor() }
    }

    /// 把设置档落到 NSCache（0＝不设限＝现行为；cost 按单页 RGBA 估算登记，
    /// totalCostLimit 才有依据）。
    private func applyRenderParams() {
        let countLimit = ThumbnailRenderParams.cacheCountLimit
        let costLimitMB = ThumbnailRenderParams.cacheCostLimitMB
        cache.countLimit = countLimit > 0 ? countLimit : 0
        cache.totalCostLimit = costLimitMB > 0 ? costLimitMB * 1_048_576 : 0
    }

    /// 当前页 ± 预取半径内的缩略预生成（半径 0＝关；已在缓存/越界跳过；
    /// 生成走与 cell 同一函数，主线程小批量——半径档位硬封顶 3）。
    private func prefetchAroundCurrentPage() {
        let radius = ThumbnailRenderParams.prefetchRadius
        guard radius > 0, let document = readerState.pdfView?.document else { return }
        let current = readerState.currentPage - 1   // 0 起
        guard current >= 0 else { return }
        for index in max(0, current - radius)...min(document.pageCount - 1, current + radius) {
            guard let page = document.page(at: index) else { continue }
            let key = NSNumber(value: index)
            guard cache.object(forKey: key) == nil else { continue }
            let size = ThumbnailRenderParams.thumbPixelSize
            let generated = page.thumbnail(of: size, for: .cropBox)
            cache.setObject(generated, forKey: key,
                            cost: ThumbnailRenderParams.perThumbnailBytes)
        }
    }

    // MARK: ESC 关闭（本地监视器；popover 自带点击外部关闭）

    private func installESCMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            isPresented = false
            return nil
        }
    }

    private func removeESCMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }
}

/// 单个缩略 cell：缩略图（懒生成 + 缓存）+ 页码 caption；当前页高亮描边、
/// 锚点页圆点角标。点击回调 1 起物理页。：已翻到的页左上角小圆点
/// （inkSecondary 系色，不新增琥珀位点——琥珀零新增位点约束）。
/// 像素尺寸可参数化（父层按设置档注入；默认＝现 320×420）。
private struct OverviewCell: View {
    let pageIndex: Int
    let page: PDFPage
    /// 本 cell 的缩略图像素尺寸（父层注入；默认档＝现 320×420）。
    let pixelSize: CGSize
    let isCurrent: Bool
    let isAnchored: Bool
    /// 本页是否已在足迹集合（isPageViewed 纯函数在父层判定）。
    let isViewed: Bool
    let onSelect: (Int) -> Void
    let cache: NSCache<NSNumber, NSImage>
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    @State private var image: NSImage?

    var body: some View {
        let theme = DS.Theme.storage(dsTheme)
        return Button {
            onSelect(pageIndex + 1)
        } label: {
            VStack(spacing: DS.Spacing.xxs) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(DS.Color.desk(theme, scheme))
                        .aspectRatio(0.76, contentMode: .fit)
                        .overlay(ProgressView().controlSize(.small))
                }
                Text("P\(pageIndex + 1)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            .padding(DS.Spacing.xxs)
            .background(RoundedRectangle(cornerRadius: DS.Radius.small)
                .fill(DS.Color.surface(theme)))
            .overlay(alignment: .topTrailing) {
                if isAnchored {
                    Circle()
                        .fill(DS.Color.ink(theme, scheme))
                        .frame(width: 8, height: 8)
                        .padding(5)
                }
            }
            .overlay(alignment: .topLeading) {
                if isViewed {
                    Circle()
                        .fill(DS.Color.inkSecondary(theme, scheme))
                        .frame(width: 6, height: 6)
                        .padding(5)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.small)
                .stroke(isCurrent ? DS.Color.ink(theme, scheme) : DS.Color.stroke(theme, scheme),
                        lineWidth: isCurrent ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("P\(pageIndex + 1)")
        .task { loadThumbnailIfNeeded() }
    }

    /// 懒生成：先查缓存，未命中主线程生成 2x 像素缩略图（160pt 显示尺寸，
    /// 生成开销可忽略；LazyVGrid 保证只建可视 cell）。像素尺寸走设置档；
    /// cost 按单页 RGBA 估算登记（缓存字节上限才可生效）。
    private func loadThumbnailIfNeeded() {
        guard image == nil else { return }
        let key = NSNumber(value: pageIndex)
        if let cached = cache.object(forKey: key) {
            image = cached
            return
        }
        let generated = page.thumbnail(of: pixelSize, for: .cropBox)
        cache.setObject(generated, forKey: key, cost: ThumbnailRenderParams.perThumbnailBytes)
        image = generated
    }
}
