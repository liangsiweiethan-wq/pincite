import Foundation
import CoreGraphics

// MARK: - f 键候选角标与 marks armed 状态机（UI 逻辑层纯值）
//
// 分层依据（Package.swift）：LiteratureSearchUI 纯 Foundation/CoreGraphics
// 可 `@testable` 测（AnnotationUndo.swift:1-3 头注先例）；AppKit 面只在
// App 层（QuotePDFView 角标 NSView keyDown）。m/' 与 f 两键
// 共用同一 armed 状态机，三模式互斥（进入一个清另一个）。
//
// 参考实现：Zathura sc_follow（shortcuts.c:368-375 字母叠标一键选定）；
// Sioyek 状态栏 "preview N/M" 轮换（main_widget.cpp:1503-1508，无鼠标/
// VoiceOver 场景降级处理）。定序契约（测试断言固定）：labels 第 1-26＝a-z、第 27＝
// aa、第 52＝az、第 53＝ba。

/// 角标字母分配：单字母 a-z 用尽后双字母 aa/az/ba…（aa..zz 共 676 组；
/// 超出 702 个候选的极端页按双字母模 676 循环——现实页不可能触及，契约
/// 如实注明）。0 候选返回空数组。分配序＝输入序稳定对应。
public enum FollowBadgeLabels {
    /// 双字母段起点（第 27 个）。
    static let singleLetterCount = 26
    /// 双字母组总数（aa..zz）。
    static let doubleLetterCount = 26 * 26

    public static func labels(count: Int) -> [String] {
        guard count > 0 else { return [] }
        var out: [String] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            if i < singleLetterCount {
                out.append(letter(at: i))
            } else {
                // 双字母段：n = i - 26；首字母 n/26（aa→az, ba→bz, …），
                // 次字母 n%26。超出 702 模 676 循环（边界如实注明）。
                let n = (i - singleLetterCount) % doubleLetterCount
                out.append(letter(at: n / 26) + letter(at: n % 26))
            }
        }
        return out
    }

    private static func letter(at index: Int) -> String {
        String(Character(UnicodeScalar(UInt8(97 + index % 26))))
    }
}

/// armed 模式（三模式互斥）。
public enum ReaderArmedMode: Equatable, Sendable {
    /// `m` 按下，等字母设标。
    case markSet
    /// `'` 按下，等字母跳回。
    case markJump
    /// `f` 按下，角标候选已铺开。
    case follow
}

/// armed 状态机纯值类型：idle → armed(mode) → 字母消耗 → idle；
/// ESC/其他键取消。持有 follow 轮换游标（◀▶/空格驱动）。
public struct FollowState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case armed(ReaderArmedMode)
    }

    public private(set) var phase: Phase = .idle
    /// follow 模式当前轮换游标（0 起；仅在 phase == .armed(.follow) 有效）。
    public private(set) var rotationIndex: Int = 0

    public init() {}

    public var isArmed: Bool {
        if case .armed = phase { return true }
        return false
    }

    public var armedMode: ReaderArmedMode? {
        if case .armed(let mode) = phase { return mode }
        return nil
    }

    /// 进入某 armed 模式（进入一个清另一个——互斥语义）；follow 进入时
    /// 轮换游标归零。已处同模式重复进入同样归零（幂等）。
    public mutating func arm(_ mode: ReaderArmedMode) {
        phase = .armed(mode)
        rotationIndex = 0
    }

    /// 取消（ESC/其他键/点击角标区外）→ idle。
    public mutating func cancel() {
        phase = .idle
        rotationIndex = 0
    }

    /// 字母消耗：返回被消费的模式并回 idle（无 armed 时返回 nil）。
    @discardableResult
    public mutating func consume() -> ReaderArmedMode? {
        guard let mode = armedMode else { return nil }
        cancel()
        return mode
    }

    /// follow 轮换前进（▶/空格）。candidateCount ≤ 0 时零变化。
    @discardableResult
    public mutating func advanceRotation(candidateCount: Int) -> Int? {
        guard case .armed(.follow) = phase, candidateCount > 0 else { return nil }
        rotationIndex = (rotationIndex + 1) % candidateCount
        return rotationIndex
    }

    /// follow 轮换后退（◀）。
    @discardableResult
    public mutating func retreatRotation(candidateCount: Int) -> Int? {
        guard case .armed(.follow) = phase, candidateCount > 0 else { return nil }
        rotationIndex = (rotationIndex - 1 + candidateCount) % candidateCount
        return rotationIndex
    }
}


/// 页内可见比例：marks.offset_y 的取值函数。输入页 bounds 与可见区域
/// （同一坐标系），输出可见区中心在页高内的 0-1 比例（clamp）。
public enum MarkOffset {
    public static func visibleRatio(pageBounds: CGRect, visibleRect: CGRect) -> Double {
        guard pageBounds.height > 0 else { return 0 }
        let visible = visibleRect.intersection(pageBounds)
        guard !visible.isNull, visible.height > 0 else { return 0 }
        let ratio = (visible.midY - pageBounds.minY) / pageBounds.height
        return Double(min(max(ratio, 0), 1))
    }
}
