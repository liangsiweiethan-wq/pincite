import Foundation
@testable import LiteratureCore
@testable import LiteratureSearchUI

// MARK: - AppSupportPaths 套件
//
// 覆盖：路径生成（根/子路径拼接）、目录创建（ensure，注入临时根，
// 绝不写真实 Application Support）、两处生产 defaultDirectory 落点
// 与统一入口一致（防漂移锁定）。

enum AppSupportPathsSuite {
    static var tests: [TestDesc] {
        [
            TestDesc(suite: "AppSupportPaths", name: "pathCompositionUnderBase") {
                let base = Fixtures.makeTempDir("appsp-comp")
                defer { Fixtures.cleanup(base) }
                // 根下 app 子目录拼接。
                let app = AppSupportPaths.directory(under: base)
                try expectEqual(app, base.appendingPathComponent("LiteratureSearch", isDirectory: true))
                // 追加子路径（多段）。
                let sub = AppSupportPaths.directory(under: base, subpath: "WebDAVImport")
                try expectEqual(sub, base.appendingPathComponent("LiteratureSearch/WebDAVImport", isDirectory: true))
                // nil / 空串子路径等价于无子路径。
                try expectEqual(AppSupportPaths.directory(under: base, subpath: ""), app)
                // ensure=false 不创建任何目录。
                try expectFalse(FileManager.default.fileExists(atPath: app.path),
                                "ensure=false 不得建目录")
            },
            TestDesc(suite: "AppSupportPaths", name: "ensureCreatesMissingDirectories") {
                let base = Fixtures.makeTempDir("appsp-ensure")
                defer { Fixtures.cleanup(base) }
                let sub = AppSupportPaths.directory(under: base, subpath: "deep/nested", ensure: true)
                var isDir: ObjCBool = false
                try expectTrue(FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDir)
                               && isDir.boolValue, "ensure=true 应建出多级目录")
                // 幂等：再 ensure 一次不报错不重建。
                let again = AppSupportPaths.directory(under: base, subpath: "deep/nested", ensure: true)
                try expectEqual(again, sub)
            },
            TestDesc(suite: "AppSupportPaths", name: "productionDefaultLocationsUnchanged") {
                // 生产落点锁定：与统一入口逐字一致（LiteratureSearch/）。
                let app = AppSupportPaths.appDirectory()
                try expectEqual(app, AppSupportPaths.baseDirectory()
                    .appendingPathComponent("LiteratureSearch", isDirectory: true))
                try expectEqual(ReadingPositionStore.defaultDirectory(), app,
                                "ReadingPositionStore 落点不变")
                try expectEqual(AIProfilesStore.defaultDirectory(), app,
                                "AIProfilesStore 落点不变")
                // 根目录取自跨平台 API：路径以 Application Support 结尾
                //（不创建、不写入）。
                try expectTrue(AppSupportPaths.baseDirectory().path
                    .hasSuffix("Application Support"), "根为用户 Application Support")
            },

            // MARK: — 存储路径安全解析（消灭 .first! 硬解包）

            TestDesc(suite: "AppSupportPaths", name: "resolveBaseNormalPathHasNoWarning") {
                let base = Fixtures.makeTempDir("appsp-resolve-ok")
                defer { Fixtures.cleanup(base) }
                let resolved = AppSupportPaths.resolveBase(from: [base])
                try expectNil(resolved.warning, "正常枚举结果必须无警告")
                try expectEqual(resolved.url, base)
            },

            TestDesc(suite: "AppSupportPaths", name: "resolveBaseEmptyListDegradesWithExplicitWarning") {
                // 空枚举（Application Support 不可用的异常环境）：明确警告 +
                // 家目录降级处理——不再硬解包崩溃。
                let resolved = AppSupportPaths.resolveBase(from: [])
                let warning = try expectNotNil(resolved.warning, "空枚举必须给出明确警告")
                try expectTrue(warning.contains("降级"), "警告应说明降级: \(warning)")
                try expectTrue(resolved.url.path.hasSuffix("Application Support"),
                               "降级处理落点与 baseDirectory() 语义一致")
            },

            TestDesc(suite: "AppSupportPaths", name: "exportDirectoryDefaultsUnderAppFolder") {
                let base = Fixtures.makeTempDir("appsp-export")
                defer { Fixtures.cleanup(base) }
                let export = AppSupportPaths.defaultExportDirectory(under: base)
                try expectEqual(export.path, base.appendingPathComponent("LiteratureSearch/exports",
                                                                    isDirectory: true).path)
                // 索引库落点组合（AppState 同式）：根下 LiteratureSearch/index.db。
                let db = AppSupportPaths.directory(under: base).appendingPathComponent("index.db")
                try expectEqual(db.path, base.appendingPathComponent("LiteratureSearch/index.db").path)
            },
        ]
    }
}
