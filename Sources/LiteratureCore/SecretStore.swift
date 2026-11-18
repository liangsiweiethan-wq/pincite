import Foundation

// MARK: - 秘密存储协议

public protocol SecretStore {
    /// 写入/覆盖。抛错 = 写失败。
    func save(_ data: String, account: String) throws
    /// 读取；nil = 无此秘密或读取失败。
    func read(account: String) -> String?
    /// 幂等删除；条目不存在不算错误。
    func delete(account: String)
}
