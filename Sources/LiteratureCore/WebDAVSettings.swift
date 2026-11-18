import Foundation

// MARK: - WebDAV 同步设置持久化（设置面板的落盘半边）
//
// 面板配置落 AppSupport JSON（webdav-sync.json），结构与 CLI
// `webdav-sync --config` 完全一致（serverBase / username / rules /
// extensions），一条规则即可（远端目录 → 本地下载落点）。
// 密码绝不进 JSON：经 SecretStore 只进本机钥匙串（独立 service，
// 见 LiteratureSearchUI/SecurityFrameworkKeyStorage.webdavService）。
// 坏档/缺档 fail-closed 视为无配置（面板回默认值，绝不半读）。

public final class WebDAVSettingsStore {
    public static let fileName = "webdav-sync.json"
    /// 默认远端目录（云盘根；建议用户改为自己驱动器内的文献目录）。
    public static let defaultRemoteDir = "/"
    /// 默认下载落点名（AppSupport/LiteratureSearch/ 下；不写进用户文献根）。
    public static let defaultLocalFolder = "WebDAVImport"

    /// 配置文件落点（默认 AppSupport/LiteratureSearch/webdav-sync.json；
    /// 测试注入临时目录）。
    public let fileURL: URL

    public init(directory: URL = AppSupportPaths.appDirectory()) {
        self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// 读配置；nil = 无配置或坏档（fail-closed：调用方回默认值）。
    public func load() -> WebDAVSyncConfig? {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(WebDAVSyncConfig.self, from: data) else {
            return nil
        }
        return config
    }

    /// 原子写配置（AppSupport 目录缺则建）。
    public func save(_ config: WebDAVSyncConfig) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(config).write(to: fileURL, options: .atomic)
    }

    /// 面板默认：一条规则（远端根 → AppSupport/WebDAVImport）。
    /// serverBase 预填 WebDAV 服务占位（用户显式改成自己的）。
    public static func defaultConfig() -> WebDAVSyncConfig {
        WebDAVSyncConfig(
            serverBase: "https://dav.example.com/webdav",
            username: "",
            rules: [WebDAVSyncRule(remoteDir: defaultRemoteDir,
                                   localRoot: AppSupportPaths.appDirectory(defaultLocalFolder))])
    }
}
