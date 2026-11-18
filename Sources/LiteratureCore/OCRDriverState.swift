import Foundation

/// OCR 双引擎状态机六态（books.ocr_status 列的合法值域）。
/// idle=未入OCR流程；queued=已排队；running=引擎在跑；merged=文本已并页；
/// rejected=配对/校验拒绝；circuitBroken=交叉验证分歧率超阈整册熔断。
public enum OCRDriverState: String, CaseIterable, Sendable {
    case idle
    case queued
    case running
    case merged
    case rejected
    case circuitBroken = "circuit-broken"
}
