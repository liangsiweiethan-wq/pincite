import Foundation

// MARK: - 读写能力约束单点

public enum WritingPolicy {
    /// idiomIsPad = `UIDevice.current.userInterfaceIdiom == .pad`（调用方
    /// 换算）。iPad 可写；iPhone 及其他 idiom 一律只读。
    public static func isWritable(idiomIsPad: Bool) -> Bool {
        idiomIsPad
    }

    /// 约束依据注记。
    public static let decisionNote =
        "产品约束：iPad 可写批注/涂画，iPhone 只读；原件 PDF 全平台只读不变。"
}
