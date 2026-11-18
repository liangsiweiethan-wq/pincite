import Foundation
@testable import LiteratureCore

// MARK: -：iOS 编译门守卫套件

enum iOSCompileGateSuite {
    /// 仓库根（本文件在 Tests/LiteratureCoreTests/ 下）。
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 递归收集目录下全部 .swift（返回相对仓库根路径，排序稳定）。
    static func swiftFiles(under relative: String) throws -> [String] {
        let root = repoRoot.appendingPathComponent(relative, isDirectory: true)
        var out: [String] = []
        var stack = [root]
        while let dir = stack.popLast() {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for item in items {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let rel = item.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                if isDir {
                    stack.append(item)
                } else if item.pathExtension == "swift" {
                    out.append(rel)
                }
            }
        }
        return out.sorted()
    }

    /// 条件编译白名单（盘点六文件 + 说明扩展两文件。
    /// 其余任何文件出现 #if os( 或 #if canImport( 即不合格。
    static let conditionalCompilationWhitelist: Set<String> = [
        "Sources/LiteratureCore/AppSupportPaths.swift",          // homeDirectoryForCurrentUser 的 #if os(macOS)
        "Sources/LiteratureSearchUI/HitRouter.swift",            // 既有 canImport
        "Sources/LiteratureSearchUI/AIProfilesStore.swift",      // 说明扩展
        "Sources/LiteratureSearchUI/ReadingPositionStore.swift", // 说明扩展
        "Sources/LiteratureSearchUI/SnippetHighlighter.swift",   // 说明扩展：macOS 依赖 LiteratureCore 模块；iOS 同模块编译下条件导入 no-op
        "Sources/LiteratureCore/PDFBurnExport.swift",            // 说明扩展：PDFAnnotation.add 路径类型平台分叉（macOS=NSBezierPath / iOS=UIBezierPath）+ 注记色构造型
        "Sources/LiteratureCore/FoundationModelsTransport.swift", // 说明扩展：FoundationModels 专属代码唯一宿主
        "Sources/LiteratureCore/OcrDrivers.swift",                // 说明扩展（跨批最小修复）：MinerU/Docling 外部进程驱动 macOS 专属（Process/Signal 无 iOS 形态），#if os(macOS) 整体防护——10-04 OCR 双引擎批落件未加护栏顶红 iOS 门，本说明件修复；macOS 产物一字不变
        "Sources/LiteratureCore/FileClone.swift",                 // 说明扩展：APFS clonefile(3) 仅 macOS 形态（fclonefileat/copyfile 无 iOS 形态），#if os(macOS) 整体防护，iOS 侧不编译此件；macOS 产物一字不变
        "Sources/LiteratureCore/LibraryFileWatcher.swift",        // 说明扩展：FSEvents/CoreServices 仅 macOS（iOS 无本地书库监听形态），#if os(macOS) 全件防护，iOS 不编译
        "Sources/LiteratureSearchUI/LibrarySnapshotStore.swift",  // 说明扩展：沿 app/iOS 同款 canImport(LiteratureCore) 双形态基准（iOS 工程同模块直编 / macOS 静态库导入）
        "Sources/LiteratureSearchUI/RefreshConsoleStore.swift",   // 实现说明扩展：沿 LibrarySnapshotStore 同款 canImport(LiteratureCore) 双形态基准（iOS 工程同模块直编 / macOS 静态库导入），实现侧随件说明
        "Sources/LiteratureSearchUI/SearchCompletion.swift",       // 说明扩展：裸 import LiteratureCore 改 canImport 双形态（iOS target 同模块直编，裸 import 必挂门），开发环境随件说明
        "Sources/LiteratureSearchUI/SearchMemoryStore.swift",      // 说明扩展：同上
        "app/iOS/LiteratureSearchiOSApp.swift",                  // 既有 canImport
        "app/iOS/PhoneWatchBridge.swift",                        // 既有 canImport
        "app/watch/LiteratureSearchWatchApp.swift",              // 既有 canImport
    ]

    static var tests: [TestDesc] {
        [
            TestDesc(suite: "iOSCompileGate", name: "conditionalCompilationOnlyInWhitelistedFiles") {
                var offenders: [String] = []
                for relative in ["Sources", "app"] {
                    for path in try swiftFiles(under: relative) {
                        guard let text = try? String(contentsOf: repoRoot.appendingPathComponent(path),
                                                     encoding: .utf8) else { continue }
                        for raw in text.components(separatedBy: "\n") {
                            let line = raw.trimmingCharacters(in: .whitespaces)
                            let hits = line.hasPrefix("#if os(") || line.hasPrefix("#if canImport(")
                            guard hits else { continue }
                            if !conditionalCompilationWhitelist.contains(path) {
                                offenders.append("\(path): \(line)")
                            }
                        }
                    }
                }
                try expectTrue(offenders.isEmpty,
                               "条件编译只许出现在白名单文件（新位点先改白名单并说明）：\n  "
                                   + offenders.joined(separator: "\n  "))
            },

            TestDesc(suite: "iOSCompileGate", name: "noForceUnwrappedFirstInSources") {
                var offenders: [String] = []
                for path in try swiftFiles(under: "Sources") {
                    guard let text = try? String(contentsOf: repoRoot.appendingPathComponent(path),
                                                 encoding: .utf8) else { continue }
                    for raw in text.components(separatedBy: "\n") {
                        // 注释提及不算调用（照 keyboardShortcut 守卫先例）。
                        guard !raw.trimmingCharacters(in: .whitespaces).hasPrefix("//"),
                              !raw.trimmingCharacters(in: .whitespaces).hasPrefix("///") else { continue }
                        if raw.contains(".first!") {
                            offenders.append(path)
                            break
                        }
                    }
                }
                try expectTrue(offenders.isEmpty, "Sources/ 内 .first! 必须保持 0 命中: \(offenders)")
            },

            TestDesc(suite: "iOSCompileGate", name: "idiomSingleFileAndWhitelistShape") {
                let iosDir = repoRoot.appendingPathComponent("app/iOS", isDirectory: true)
                var isDir: ObjCBool = false
                try expectTrue(FileManager.default.fileExists(atPath: iosDir.path, isDirectory: &isDir) && isDir.boolValue,
                               "app/iOS 目录必须在位")
                var idiomFiles: [String] = []
                for path in try swiftFiles(under: "app/iOS") {
                    let text = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
                    if text.contains("userInterfaceIdiom") { idiomFiles.append(path) }
                }
                try expectEqual(Set(idiomFiles), Set(["app/iOS/WritingCapability.swift"]),
                                "userInterfaceIdiom 只许出现在 WritingCapability.swift")
                // 白名单文件必须真实存在（防止守卫漂成空转）。
                for path in conditionalCompilationWhitelist {
                    try expectTrue(FileManager.default.fileExists(
                        atPath: repoRoot.appendingPathComponent(path).path),
                        "白名单文件必须在位: \(path)")
                }
            },
        ]
    }
}
