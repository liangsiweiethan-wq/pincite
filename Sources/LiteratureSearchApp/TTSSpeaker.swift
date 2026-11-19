import AVFoundation
import SwiftUI

/// TTS 朗读：AVSpeechSynthesizer 薄封装（纯本地 API，零网络）。
/// 只朗读调用方给定的页原文文本（索引库 text_original），不触碰原书 PDF。
/// 生命周期：speak 先停旧句；stop 立即中断；App 退出（willTerminate）自动停。
final class TTSSpeaker: NSObject, ObservableObject {
    /// 朗读中状态（ReadingChrome 据此切换「朗读此页」/「停止」+ 状态 caption）。
    @Published private(set) var speaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var speechDelegate: SpeechDelegate?
    private var terminateObserver: NSObjectProtocol?

    override init() {
        super.init()
        let delegate = SpeechDelegate { [weak self] in
            Task { @MainActor in self?.speaking = false }
        }
        self.speechDelegate = delegate
        synthesizer.delegate = delegate
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                self?.stop()
            }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    /// 朗读文本：voice 按文本语言自动匹配（含 CJK → zh-CN，否则 en-US）。
    /// 空文本不启动（调用方负责禁用入口）。
    func speak(text: String) {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.isCJK(trimmed) ? "zh-CN" : "en-US")
        synthesizer.speak(utterance)
        speaking = true
    }

    /// 立即停止当前朗读（可中断；换书/关详情/退出共用此入口）。
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        speaking = false
    }

    /// 文本含 CJK 统一表意文字（U+4E00–U+9FFF）即按中文匹配嗓音（逐字，
    /// 不做语言猜测以外的检测——与索引库 language 字段基准无关，仅影响
    /// 嗓音选择）。用码位区间而非正则，避免 CJK 字面量回流视图层。
    private static func isCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}

/// AVSpeechSynthesizerDelegate 桥（didFinish/didCancel 复位朗读状态）。
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinish()
    }
}
