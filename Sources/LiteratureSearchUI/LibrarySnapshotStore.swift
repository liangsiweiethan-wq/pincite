import Foundation
import Combine
#if canImport(LiteratureCore)
import LiteratureCore
#endif


public final class LibrarySnapshotStore: ObservableObject {
    /// 快照落点（生产：Application Support/LiteratureSearch/snapshots/）。
    public let snapshotDir: URL
    /// 备份/恢复的库源（macOS 形态见文件头基准说明）。
    public private(set) var sources: [(name: String, url: URL)]
    /// 快照保留份数（透传 SnapshotManager.keep）。
    public let keep: Int

    @Published public private(set) var busy = false
    @Published public private(set) var message = ""
    @Published public private(set) var snapshots: [URL] = []

    /// indexDBURL 传 nil 时按 AppSupportPaths 生产基准推导（与 AppState
    /// dbURL 同源：AppSupportPaths.directory(under:)＋index.db）；设置页
    /// 接线传 AppState.dbURL（活库真实路径，含降级解析警告态）。
    public init(indexDBURL: URL? = nil, snapshotDir: URL? = nil, keep: Int = 1) {
        self.snapshotDir = snapshotDir ?? AppSupportPaths.appDirectory("snapshots")
        let db = indexDBURL ?? AppSupportPaths.appDirectory().appendingPathComponent("index.db")
        self.sources = [("index", db)]
        self.keep = keep
        reload()
    }

    /// 快照管理器（值语义，随取随建；测试注入点全部留给 SnapshotManager）。
    public func manager() -> SnapshotManager {
        SnapshotManager(snapshotDir: snapshotDir, sources: sources, keep: keep)
    }

    /// 刷新快照清单（listSnapshots 只认 yyyyMMdd-HHmmss 命名，pre-restore
    /// 安全网目录天然被滤除，见 SnapshotManager.restore）。
    public func reload() {
        snapshots = manager().listSnapshots()
    }

    // MARK: 同步核心（合成测试直走）

    /// 备份当前库（SnapshotManager.takeSnapshot：任一源失败删半成品目录，
    /// keep 份自动清理）。
    @discardableResult
    public func backupNow() throws -> URL {
        try manager().takeSnapshot()
    }

    /// 从快照恢复（SnapshotManager.restore：前置校验零接触目标库→安全网
    /// 备份当前库→暂存→原子替换→中途失败回滚）。
    public func restoreNow(_ snapshot: URL) throws {
        try manager().restore(snapshot: snapshot, to: sources)
    }

    // MARK: UI 包装（面板交互沿用设置页既有 busy/状态行风格）

    /// 备份：后台执行，主线程发布结果与刷新后的清单。
    public func backup() {
        guard !busy else { return }
        busy = true
        message = L10n.librarySnapshotWorking
        let mgr = manager()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try mgr.takeSnapshot() }
            DispatchQueue.main.async {
                self?.finish(result.map { $0.lastPathComponent },
                             ok: { L10n.librarySnapshotBackupOK($0) })
            }
        }
    }

    /// 恢复：后台执行；完成后提示重启 App（活连接仍指旧 inode，不装即时生效）。
    public func restore(_ snapshot: URL) {
        guard !busy else { return }
        busy = true
        message = L10n.librarySnapshotRestoreWorking
        let mgr = manager()
        let sources = self.sources
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try mgr.restore(snapshot: snapshot, to: sources) }
            DispatchQueue.main.async {
                self?.finish(result.map { _ in snapshot.lastPathComponent },
                             ok: { L10n.librarySnapshotRestoreOK($0) })
            }
        }
    }

    /// 后台任务结算：主线程发布（成功带快照名，失败带错误原文——不吞不饰）。
    private func finish(_ result: Result<String, Error>, ok: (String) -> String) {
        busy = false
        switch result {
        case .success(let name):
            message = ok(name)
            reload()
        case .failure(let error):
            message = L10n.librarySnapshotFailedPrefix + error.localizedDescription
        }
    }
}
