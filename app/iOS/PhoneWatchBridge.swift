import Foundation
import WatchConnectivity
// Core sources are compiled into this target for iOS Xcode builds; the import
// only applies when LiteratureCore comes from the macOS static library.
#if canImport(LiteratureCore)
import LiteratureCore
#endif

// iOS-side WatchConnectivity adapter.
//
// Thin on purpose: every byte that crosses to the watch is serialized by the
// core (WatchSummaryCodec / WatchCompanionCodec), so the synthetic tests cover
// the payload contract. This class only moves an already-encoded payload.
// Personal-team build: no CloudKit, no background refresh tricks — one
// explicit application-context push per user action (merged, see below).

final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    static let payloadKey = "watch-summary-v1"

    private var session: WCSession?
    private var stateChangeHandler: ((String) -> Void)?
    /// In-process slots of the most recent SUCCESSFULLY pushed bytes.
    /// Assign only after a successful push; failed bytes never enter the next push.
    /// applicationContext is ONE slot per app and every update REPLACES the
    /// whole dictionary — every push must carry BOTH keys via
    /// WatchCompanion.makeContext.
    private var lastSummaryData: Data?
    private var lastCompanionData: Data?
    /// 双槽是进程内存态，跨启动清零。推送前若摘要槽为空，由
    /// provider 现场重建（SharedHistoryStore 常在，空历史也是合法摘要）——
    /// 伴侣推送必伴摘要，从发送侧根除伴侣单键 context。
    var summaryProvider: (() -> WatchSummary?)?

    func activate(onStateChange: @escaping (String) -> Void) {
        stateChangeHandler = onStateChange
        guard WCSession.isSupported() else {
            onStateChange("本机不支持 WatchConnectivity")
            return
        }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        session = s
    }

    /// Sends the truncated summary as the application context (one slot,
    /// always the latest wins — exactly the semantics a summary needs).
    /// Companion key rides along from the last successful companion push, so
    /// existing callers keep their behavior unchanged.
    func send(_ summary: WatchSummary) throws {
        guard let session else { throw BridgeError.notActivated }
        guard session.activationState == .activated else { throw BridgeError.notActivated }
        guard session.isPaired else { throw BridgeError.watchNotPaired }
        guard session.isWatchAppInstalled else { throw BridgeError.watchAppNotInstalled }
        let newSummary = try WatchSummaryCodec.encode(summary)
        let companion = lastCompanionData
        try pushMergedContext(summary: newSummary, companion: companion)
        lastSummaryData = newSummary
        lastCompanionData = companion
    }

    /// pushes the companion payload (daily quote + progress). The
    /// summary key ALWAYS rides along: last successful summary push, or a
    /// provider rebuild (a fresh process must never emit a
    /// companion-only context, which would wipe the summary key wholesale).
    func sendCompanion(_ data: Data) throws {
        guard let session else { throw BridgeError.notActivated }
        guard session.activationState == .activated else { throw BridgeError.notActivated }
        guard session.isPaired else { throw BridgeError.watchNotPaired }
        guard session.isWatchAppInstalled else { throw BridgeError.watchAppNotInstalled }
        var summary = lastSummaryData
        if summary == nil, let provider = summaryProvider, let rebuilt = provider() {
            summary = try WatchSummaryCodec.encode(rebuilt)
        }
        try pushMergedContext(summary: summary, companion: data)
        lastSummaryData = summary
        lastCompanionData = data
    }

    /// THE single application-context push call site: the merged two-key
    /// dictionary built by the Core contract function.
    private func pushMergedContext(summary: Data?, companion: Data?) throws {
        guard let session else { throw BridgeError.notActivated }
        let context = try WatchCompanion.makeContext(
            summaryKey: Self.payloadKey, summary: summary,
            companionKey: WatchCompanion.contextKey, companion: companion)
        try session.updateApplicationContext(context)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            stateChangeHandler?("WatchConnectivity 激活失败：\(error.localizedDescription)")
        } else {
            stateChangeHandler?("WatchConnectivity 已激活（状态 \(activationState.rawValue)）")
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate() // re-activate for the next paired watch
    }

    enum BridgeError: LocalizedError {
        case notActivated
        case watchNotPaired
        case watchAppNotInstalled

        var errorDescription: String? {
            switch self {
            case .notActivated: return "WatchConnectivity 未激活"
            case .watchNotPaired: return "未配对 Apple Watch"
            case .watchAppNotInstalled: return "手表端未安装应用"
            }
        }
    }
}
