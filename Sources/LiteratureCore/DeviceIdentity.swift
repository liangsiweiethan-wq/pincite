import Foundation

// MARK: - 设备标识（冲突模型的 device_id）
//
// 首次调用生成 UUID 存 UserDefaults（键固定），此后稳定返回——同一台
// 设备永远同一个 ID（append-only + 墓碑冲突模型的判别键）。
// 注入 defaults 可测：测试传临时 suite 的 UserDefaults，绝不写真实
// standard。纯 Foundation。

public enum DeviceIdentity {
    /// UserDefaults 键（固定；改动即换设备身份，禁改）。
    public static let defaultsKey = "literaturesearch.device_id"

    /// 读取或首建设备 ID（幂等：第二次调用返回与首次相同值）。
    public static func deviceID(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }
}
