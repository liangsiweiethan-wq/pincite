import Foundation

// MARK: - Application Support 统一路径
//
// 全包此前有两处重复的根目录推导（ReadingPositionStore.defaultDirectory 与
// AIProfilesStore.defaultDirectory，各含一份 homeDirectoryForCurrentUser
// 降级处理）——收拢至此唯一入口。落点语义不变：仍为用户 Application Support
// 下的 LiteratureSearch/。取根用跨平台 API
// FileManager.url(for: .applicationSupportDirectory, in: .userDomainMask)，
// App 沙盒化后自动指向容器内同名目录，调用方零改动。
// 纯 Foundation；合成测试只走注入临时根的 directory(under:) 通道，
// 绝不写真实 Application Support。

public enum AppSupportPaths {
    /// 本 App 在 Application Support 下的子目录名。
    public static let appFolder = "LiteratureSearch"

    /// 生产根：用户 Application Support（不创建）。
    public static func baseDirectory() -> URL {
        #if os(macOS)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        #else
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    /// 在给定根下组装 LiteratureSearch/（可再接子路径）。
    /// ensure=true 时按 mkdir -p 语义创建缺目录（失败静默，返回原路径，
    /// 由写入点自行报错——与既有 persist 的容错基准一致）。
    /// 纯函数便于合成测试：传入临时根，不触真实用户目录。
    public static func directory(under base: URL, subpath: String? = nil,
                                 ensure: Bool = false) -> URL {
        var dir = base.appendingPathComponent(appFolder, isDirectory: true)
        if let subpath, !subpath.isEmpty {
            dir = dir.appendingPathComponent(subpath, isDirectory: true)
        }
        if ensure {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 生产便利：默认根下的 LiteratureSearch/（可再接子路径）。
    public static func appDirectory(_ subpath: String? = nil, ensure: Bool = false) -> URL {
        directory(under: baseDirectory(), subpath: subpath, ensure: ensure)
    }

    // MARK: — 存储路径安全解析与导出目录

    /// 显式解析根目录（注入 urls 的纯函数，可测）：urls 为空（Application
    /// Support 不可枚举的异常环境）时退回降级处理并给出警告——调用方把
    /// 警告展示给用户，不再像旧代码那样 first 强解包直接崩溃。
    public static func resolveBase(from urls: [URL]) -> (url: URL, warning: String?) {
        if let first = urls.first {
            return (first, nil)
        }
        #if os(macOS)
        return (FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support"),
                "Application Support 目录不可用，已降级到家目录路径（数据落点可能异常）")
        #else
        let fallback = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return (fallback,
                "Application Support 目录不可用，已降级到 Documents 路径（数据落点可能异常）")
        #endif
    }

    /// 默认导出目录：AppSupport/LiteratureSearch/exports/（UserDefaults 未
    /// 设置时的落点；导出动作的 NSSavePanel 以此为初始目录）。
    public static func defaultExportDirectory(under base: URL) -> URL {
        directory(under: base, subpath: "exports")
    }

    // MARK: 更新 — 抽取文本侧车缓存目录

    /// 抽取文本缓存目录：AppSupport/LiteratureSearch/text-cache/。
    public static func textCacheDirectory(under base: URL) -> URL {
        directory(under: base, subpath: "text-cache")
    }
}
