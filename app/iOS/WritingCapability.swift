import UIKit

// MARK: - 读写能力单点

enum WritingCapability {
    static var isWritable: Bool {
        WritingPolicy.isWritable(idiomIsPad: UIDevice.current.userInterfaceIdiom == .pad)
    }

    /// 只读态的展示文案（设置页/阅读器共用一句，别处不重写）。
    static var readOnlyNotice: String {
        isWritable ? "" : L10n.iosReadOnlyDeviceNotice
    }
}
