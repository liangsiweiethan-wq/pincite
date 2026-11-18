import SwiftUI
import WatchConnectivity
import WidgetKit
// Core sources are compiled into this target for watchOS Xcode builds; the
// import only applies when LiteratureCore comes from a static library.
#if canImport(LiteratureCore)
import LiteratureCore
#endif

// watchOS app — SUMMARY + COMPANION (development-signing constraint).
// It displays whatever truncated WatchSummary and companion payload
// (daily quote + reading progress) last arrived from the paired iPhone.
// No searching, no book content, no credentials, no network of its own.
// Expired data (older than the TTL) is labelled stale instead of hidden.

@main
struct LiteratureSearchWatchApp: App {
    @StateObject private var receiver = WatchSummaryReceiver()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchSummaryView(summary: receiver.summary, staleNote: receiver.staleNote,
                                 companion: receiver.companion,
                                 companionNote: receiver.companionStaleNote)
            }
        }
    }
}

struct WatchSummaryView: View {
    var summary: WatchSummary?
    var staleNote: String?
    var companion: WatchCompanionPayload?
    var companionNote: String?

    var body: some View {
        List {
            if let s = summary {
                Section("索引摘要") {
                    Text("书 \(s.bookCount) · 页 \(s.pageCount)").font(.headline)
                    Text("无文本页 \(s.pagesWithoutText)（未OCR）").font(.caption2)
                    if s.errorBooks > 0 { Text("错误书目 \(s.errorBooks)").font(.caption2) }
                    Text("生成于 \(s.generatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if !s.queries.isEmpty {
                    Section("最近检索") {
                        ForEach(Array(s.queries.enumerated()), id: \.offset) { _, q in
                            Text(q).font(.caption).lineLimit(1)
                        }
                    }
                }
                if s.truncated {
                    Section {
                        Text("摘要已截断（只保留最近几条）").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    Text("等待 iPhone 发送摘要…").font(.caption)
                }
            }
            // 伴侣面：今日一句 + 阅读进度；陈旧标注不隐藏。
            if let c = companion {
                if let q = c.dailyQuote {
                    Section("今日一句") {
                        Text(q.sentence).font(.headline)
                        Text("\(q.bookTitle) · 第 \(q.physicalPage) 页 · \(q.date)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let p = c.progress {
                    Section("阅读进度") {
                        Text(p.bookTitle).font(.headline)
                        Text("第 \(p.page) / \(max(p.pageCount, p.page)) 页").font(.caption2)
                        Text("更新于 \(p.updatedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("最后更新 \(c.pushedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                    if c.isExpired() {
                        Text("已过期（超过 24 小时），等 iPhone 下次推送")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    Text("等待 iPhone 推送…").font(.caption)
                }
            }
            if let note = staleNote {
                Section { Text(note).font(.caption2).foregroundStyle(.secondary) }
            }
            if let note = companionNote {
                Section { Text(note).font(.caption2).foregroundStyle(.secondary) }
            }
            Section {
                Text("手表端仅显示摘要与今日一句/进度：不检索、不存储原文。").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("文献摘要")
    }
}

/// Receives application-context / user-info payloads from the iPhone, decodes
/// them through the core codec and caches the latest bytes for the widget.
final class WatchSummaryReceiver: NSObject, ObservableObject, WCSessionDelegate {
    @Published var summary: WatchSummary?
    @Published var staleNote: String?
    /// 伴侣载荷（今日一句 + 阅读进度；与摘要同槽合并推送）。
    @Published var companion: WatchCompanionPayload?
    @Published var companionStaleNote: String?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        } else {
            staleNote = "本机不支持 WatchConnectivity"
        }
        ingest(WCSession.default.receivedApplicationContext)
        // 无连接降级处理：iPhone 不可达时显示缓存内容与最后更新时间
        // （缓存过期照常显示，由 isExpired 标注陈旧，不隐藏）。
        if companion == nil,
           let data = WatchCompanionCache.load(),
           let cached = try? WatchCompanionCodec.decode(data) {
            companion = cached
        }
    }

    private func ingest(_ context: [String: Any]) {
        // 键分派走 Core 纯函数：两键各自独立读取——
        // 伴侣单键 context 不因摘要键缺失被整包丢弃（反之亦然，两个方向都保留）。
        let (summaryData, companionData) = WatchCompanion.splitContext(
            context, summaryKey: PhoneWatchBridgePayload.key,
            companionKey: WatchCompanion.contextKey)
        if let data = summaryData {
            do {
                let decoded = try WatchSummaryCodec.decode(data)
                DispatchQueue.main.async {
                    self.summary = decoded
                    self.staleNote = decoded.isExpired() ? "摘要已过期（超过 \(Int(WatchSummaryLimits.defaultMaxAge / 3600)) 小时），请在 iPhone 上重新发送" : nil
                }
                WatchSummaryCache.save(data)
            } catch {
                DispatchQueue.main.async { self.staleNote = "摘要解码失败：\(error)" }
            }
        }
        // 伴侣分支独立解码；成功后清除失败状态并刷新 complication 时间线。
        if let companionData {
            do {
                let decoded = try WatchCompanionCodec.decode(companionData)
                DispatchQueue.main.async {
                    self.companion = decoded
                    self.companionStaleNote = nil
                }
                WatchCompanionCache.save(companionData)
                WidgetCenter.shared.reloadTimelines(ofKind: "DailyQuoteWatchWidget")
            } catch {
                DispatchQueue.main.async { self.companionStaleNote = "伴侣数据解码失败：\(error)" }
            }
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            DispatchQueue.main.async { self.staleNote = "WatchConnectivity 激活失败：\(error.localizedDescription)" }
        }
        ingest(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        ingest(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        ingest(userInfo)
    }
}

/// Payload key shared with the iOS bridge (kept literal here: the watch target
/// does not compile the iOS bridge source).
enum PhoneWatchBridgePayload {
    static let key = "watch-summary-v1"
}
