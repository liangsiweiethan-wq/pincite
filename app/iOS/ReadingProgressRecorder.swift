import Foundation
// Core sources are compiled directly into this target (same module): Core
// types are used without any import — matching LibraryModel.swift, and keeping
// this file OUT of the conditional-compilation whitelist (the whitelist must not grow).

// MARK: - 阅读进度单槽记录 + 伴侣推送节奏
//
// 纯 Foundation 数据件：进度是本机偏好/展示数据——不进 annotations.db、
// 不进索引库、不写原件。单槽最新值 JSON 落 Application Support/
// LiteratureSearch/reading-progress.json（不出 iPhone；上表的只是载荷字段，
// 载荷合同在 Core WatchCompanion.swift）。
//
// 写容错照 WatchSummaryCache.save（try? + .atomic）；load 坏数据返回 nil
// （fail-closed 视为无进度）。

struct ReadingProgressRecord: Codable, Equatable {
    var bookID: String
    var bookTitle: String
    var bookFileName: String
    /// 物理页，1 起（见 docs/PAGE-BASIS.md 的物理页基准）。
    var page: Int
    var pageCount: Int
    var updatedAt: Date
}

enum ReadingProgressRecorder {
    static var fileURL: URL {
        AppSupportPaths.appDirectory("reading-progress.json")
    }

    /// 单槽覆盖写（最新一次翻页即真相）。
    static func record(_ progress: ReadingProgressRecord) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 坏数据 → nil（fail-closed 视为无进度）。
    static func load() -> ReadingProgressRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ReadingProgressRecord.self, from: data)
    }

    /// 载荷映射（字段一一对应；截断由 Core WatchCompanion.build 统一执行）。
    static func companionProgress() -> WatchReadingProgress? {
        load().map { record in
            WatchReadingProgress(bookTitle: record.bookTitle,
                                 bookFileName: record.bookFileName,
                                 page: record.page,
                                 pageCount: record.pageCount,
                                 updatedAt: record.updatedAt)
        }
    }

    // MARK: 推送节奏的持久化（显式事件驱动，无轮询）

    private static let lastPushAtKey = "watch.lastCompanionPushAt"
    private static let lastPushDateKey = "watch.lastCompanionPushDate"

    /// 60s 节流读点（shouldPush 的 lastPush 入参）。
    static var lastCompanionPushAt: Date? {
        UserDefaults.standard.object(forKey: lastPushAtKey) as? Date
    }

    /// 每日一次闸门读点（needsRepick 的 cachedDate 入参）。
    static var lastCompanionPushDate: String? {
        UserDefaults.standard.string(forKey: lastPushDateKey)
    }

    /// 仅在推送成功后调用：同时落 60s 节流点与当日日期键。
    static func markCompanionPushed(now: Date = Date()) {
        UserDefaults.standard.set(now, forKey: lastPushAtKey)
        UserDefaults.standard.set(WatchCompanion.dateString(now), forKey: lastPushDateKey)
    }
}
