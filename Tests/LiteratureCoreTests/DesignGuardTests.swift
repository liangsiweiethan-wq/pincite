import Foundation
import LiteratureCore
import LiteratureSearchUI

// MARK: - Design guard suite (grep-level)

enum DesignGuardSuite {
    /// Repo root derived from this file's location
    /// (<repo>/Tests/LiteratureCoreTests/DesignGuardTests.swift).
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LiteratureCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    static func appSources() throws -> [(name: String, text: String)] {
        let dir = repoRoot.appendingPathComponent("Sources/LiteratureSearchApp")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return try files
            .filter { $0.pathExtension == "swift" }
            .map { (name: $0.lastPathComponent,
                    text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Sources/ 全部 swift 源文本（core+ui+app 递归；守卫用）。
    static func allSources() throws -> [(name: String, text: String)] {
        let root = repoRoot.appendingPathComponent("Sources")
        var out: [(name: String, text: String)] = []
        let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "swift" {
                out.append((name: "\(dir.lastPathComponent)/\(file.lastPathComponent)",
                            text: try String(contentsOf: file, encoding: .utf8)))
            }
        }
        return out
    }

    /// Every line that touches the OCR amber. Keyed by "file|trimmed line"
    /// so a moved site fails loudly instead of silently passing.
    /// categories: badge=来源徽章 status=OCR 状态行 preview=预览卡标注 spine=书脊条 impl=组件实现/映射
    static let amberWhitelist: [String] = [
        // DesignSystem.swift —— 声明与组件内部映射（impl）
        "DesignSystem.swift|static let ocr = adaptive(\"ls.ocr\",",
        "DesignSystem.swift|case .ocr: return ocr(theme, scheme)",
        "DesignSystem.swift|? DS.Color.ocr(theme, scheme)",                       // BookSpine（spine 组件实现）
        // SearchResultListView.swift —— 书脊条(OCR)（调用点 + 组件实现）+ 来源徽章
        "SearchResultListView.swift|color: spineSource == \"ocr\" ? DS.Color.ocr(theme, scheme)",
        "SearchResultListView.swift|color: DS.Color.ocr(theme, scheme))",
        // ReadingChrome.swift —— 来源徽章 + OCR 状态行
        "ReadingChrome.swift|? DS.Color.ocr(theme, scheme)",
        "ReadingChrome.swift|.foregroundStyle(DS.Color.ocr(theme, scheme))",
        // ZeroHitView.swift —— 零命中无文字层说明（OCR 状态行）
        "ZeroHitView.swift|.foregroundStyle(DS.Color.ocr(theme, scheme))",
        // LibrarySettingsView.swift —— OCR 导入结果状态行（OCR 状态行）
        "LibrarySettingsView.swift|color: DS.Color.ocr(theme, scheme))",
        // AIPreviewPanel.swift —— 预览卡标注（hairline 描边 + 文字，同属一处；琥珀底色块收敛为 1px 描边，合法位置不变）
        "AIPreviewPanel.swift|.foregroundStyle(DS.Color.ocr(theme, scheme))",
        "AIPreviewPanel.swift|.stroke(DS.Color.ocr(theme, scheme), lineWidth: 1))",
        // CoverageView.swift —— 无文字层统计牌（来源信号徽章语义）
        "CoverageView.swift|status: .ocr, isActive: activeFilter == .ocr) {",
        "CoverageView.swift|if stat.pagesWithText == 0 { return .ocr }",
    ]

    static var tests: [TestDesc] {
        testsWith(sources: (try? appSources()) ?? [])
    }

    /// 可注入形态（A11yAuditTests 用桩文本做正反例；生产路径走 appSources）。
    static func testsWith(sources: [(name: String, text: String)]) -> [TestDesc] {
        [
            TestDesc(suite: "DesignGuard", name: "accentOcrOnlyAtWhitelistedSites") {
                let sources = try appSources()
                var seen = Set<String>()
                var illegal: [String] = []
                for (name, text) in sources {
                    for raw in text.components(separatedBy: "\n") {
                        let line = raw.trimmingCharacters(in: .whitespaces)
                        let isOCRStatusReturn = raw.range(
                            of: #"return \.ocr([^A-Za-z]|$)"#,
                            options: .regularExpression) != nil
                        let touchesAmber =
                            line.contains("DS.Color.ocr")
                            || line.contains("static let ocr = adaptive(")
                            || line.contains("case .ocr: return ocr")
                            || line.contains("status: .ocr,")
                            || isOCRStatusReturn
                        guard touchesAmber else { continue }
                        let key = "\(name)|\(line)"
                        if amberWhitelist.contains(key) {
                            seen.insert(key)
                        } else {
                            illegal.append(key)
                        }
                    }
                }
                try expectTrue(illegal.isEmpty,
                               "accent-ocr used outside its legal whitelist:\n  "
                               + illegal.joined(separator: "\n  "))
                let missing = amberWhitelist.filter { !seen.contains($0) }
                try expectTrue(missing.isEmpty,
                               "whitelisted amber sites missing (drifted):\n  "
                               + missing.joined(separator: "\n  "))
            },

            TestDesc(suite: "DesignGuard", name: "readingSerifProbesSongtiAndFallsBackToSystemFont") {
                let ds = try appSources().first { $0.name == "DesignSystem.swift" }
                let text = try expectNotNil(ds?.text)
                try expectTrue(text.contains("NSFont(name: \"Songti SC\", size: 15)"),
                               "Songti SC availability probe must exist (DS-O1)")
                try expectTrue(text.contains("NSFont.systemFont(ofSize: size)"),
                               "Songti fallback must be NSFont.systemFont (DS-O1)")
            },

            TestDesc(suite: "DesignGuard", name: "readingChromeHonorsAccessibilityReduceMotion") {
                let rc = try appSources().first { $0.name == "ReadingChrome.swift" }
                let text = try expectNotNil(rc?.text)
                try expectTrue(text.contains("accessibilityReduceMotion"),
                               "ReadingChrome must consult accessibilityReduceMotion (§2.4 注记)")
            },

            // 安全约束：sha256 表述只称「防损坏/防传输错误」，全仓源码
            // 禁出现「防篡改」（manifest 与快照同通道，不声称防恶意篡改）。
            TestDesc(suite: "DesignGuard", name: "sourcesMakeNoTamperResistanceClaims") {
                let sources = try allSources()
                let offenders = sources.filter { $0.text.contains("防篡改") }.map(\.name)
                try expectTrue(offenders.isEmpty,
                               "「防篡改」表述只允许出现在禁入源码（安全约束）：\(offenders)")
            },

            // `.keyboardShortcut(` 仅容许出现于 KeybindingBridge.swift；
            // 两处语义键（.cancelAction / .defaultAction，系统 cancel/default
            // 角色，非实键绑定）豁免单列。新快捷键不进注册表即 fail（键位债务
            // 不再生）。
            TestDesc(suite: "DesignGuard", name: "keyboardShortcutsOnlyViaRegistryBridge") {
                let sources = try allSources()
                let bridge = "LiteratureSearchApp/KeybindingBridge.swift"
                var offenders: [String] = []
                for (name, text) in sources {
                    guard "\(name)" != bridge else { continue }
                    for raw in text.components(separatedBy: "\n") {
                        let line = raw.trimmingCharacters(in: .whitespaces)
                        guard line.contains(".keyboardShortcut(") else { continue }
                        // 注释提及不算调用（本守卫锁的是代码路径）。
                        guard !line.hasPrefix("//") else { continue }
                        let isSemanticExempt = line.contains(".cancelAction")
                            || line.contains(".defaultAction")
                        if !isSemanticExempt {
                            offenders.append("\(name): \(line)")
                        }
                    }
                }
                try expectTrue(offenders.isEmpty,
                               "keyboard shortcuts must go through the registry bridge "
                               + "(KeybindingBridge.swift only):\n  "
                               + offenders.joined(separator: "\n  "))
            },

            // 守卫 (a) 动效门：凡含动画调用的文件必须同文件含
            // reduceMotion 门或豁免注记（文件级配对断言）。
            TestDesc(suite: "DesignGuard", name: "animatedFilesGateReduceMotion") {
                let sources = try appSources()
                let offenders = A11yGuards.motionGateViolations(sources.map { ("\($0.name)", $0.text) })
                try expectTrue(offenders.isEmpty,
                               "animated files must gate on reduceMotion (or annotate the "
                               + "opacity-only exemption):\n  "
                               + offenders.joined(separator: "\n  "))
            },

            // 守卫 (b) 对比度：DesignSystem.swift 必须含
            // colorSchemeContrast（SwiftUI 通道；AppKit KVO 等价物并存）。
            TestDesc(suite: "DesignGuard", name: "designSystemHasContrastChannel") {
                let sources = try appSources()
                let offenders = A11yGuards.contrastGateViolations(sources.map { ("\($0.name)", $0.text) })
                try expectTrue(offenders.isEmpty,
                               "DesignSystem.swift must carry the colorSchemeContrast channel")
            },

            // detached 回写必须带乱序代次守卫
            // （App 模块测试不可达——synthetic runner 不 import Literature
            // SearchApp，AppState 无法实例化；照 amberWhitelist 文本守卫先例）。
            TestDesc(suite: "DesignGuard", name: "searchApplyGuardedByGeneration") {
                let state = try appSources().first { $0.name == "AppState.swift" }
                let text = try expectNotNil(state?.text)
                try expectTrue(text.contains("searchGeneration += 1"),
                               "search() must advance the search generation")
                try expectTrue(text.contains("guard generation == searchGeneration else { return }"),
                               "applySearchResults must be guarded by generation (stale-write drop)")
                try expectTrue(text.contains("searchTask?.cancel()"),
                               "a new search must cancel the in-flight one")
            },

            // 守卫：CITATION-SCENARIOS.md 必须含全部 21 体例（allCases
            // 驱动——新体例不写文档即 fail）。
            TestDesc(suite: "DesignGuard", name: "citationScenariosDocListsAllStyles") {
                let docURL = repoRoot.appendingPathComponent("docs/CITATION-SCENARIOS.md")
                let text = try String(contentsOf: docURL, encoding: .utf8)
                let missing = CitationStyle.allCases.filter { style in
                    !text.contains(style.rawValue) && !text.contains(style.displayName)
                }
                try expectTrue(missing.isEmpty,
                               "CITATION-SCENARIOS.md must list every CitationStyle "
                               + "(case name or displayName): \(missing.map(\.rawValue))")
            },

            // 守卫：引注文档必含页码基准字样与文件存在性。
            TestDesc(suite: "DesignGuard", name: "citationScenariosDocMentionsPageBasis") {
                let docURL = repoRoot.appendingPathComponent("docs/CITATION-SCENARIOS.md")
                try expectTrue(FileManager.default.fileExists(atPath: docURL.path),
                               "docs/CITATION-SCENARIOS.md must exist")
                let text = try String(contentsOf: docURL, encoding: .utf8)
                for term in ["物理页", "印刷页", "PAGE-BASIS"] {
                    try expectTrue(text.contains(term),
                                   "CITATION-SCENARIOS.md must mention 「\(term)」")
                }
            },

            // 守卫：App 层硬删调用点保持 0 命中（四个删除调用点已
            // 全部改走软删 + toast 撤销通道；HighlightStore.delete(id:) 硬删
            // API 本体保留在 Core，此守卫只锁 App 调用面防回潮）。
            TestDesc(suite: "DesignGuard", name: "appLayerHasNoHardDeleteCallSites") {
                let offenders = try appSources().compactMap { file -> String? in
                    let hits = file.text.components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { $0.contains("store.delete(id:") && !$0.hasPrefix("//") }
                    return hits.isEmpty ? nil : "\(file.name): \(hits.joined(separator: " | "))"
                }
                try expectTrue(offenders.isEmpty,
                               "App 层禁直接硬删批注（删除走 softDelete + "
                               + "toast 撤销通道；防回潮机检）：\n  "
                               + offenders.joined(separator: "\n  "))
            },

            TestDesc(suite: "DesignGuard", name: "newCoreStoresAreFoundationOnly") {
                let sources = try allSources()
                let guarded = ["LiteratureCore/MarksStore.swift",
                               "LiteratureCore/ReadingSessionStore.swift",
                               "LiteratureCore/WorkbenchMapping.swift"]
                for name in guarded {
                    guard let file = sources.first(where: { $0.name == name }) else {
                        try failTest("守卫对象缺失（新 Core 文件应在册）：\(name)")
                        return
                    }
                    for raw in file.text.components(separatedBy: "\n") {
                        let line = raw.trimmingCharacters(in: .whitespaces)
                        guard line.hasPrefix("import ") else { continue }
                        try expectFalse(line.contains("AppKit") || line.contains("UIKit"),
                                        "\(name) 禁 AppKit/UIKit import：\(line)")
                    }
                }
            },

            TestDesc(suite: "DesignGuard", name: "keyDownOverrideOnlyInQuotePDFView") {
                let sources = try allSources()
                let home = "LiteratureSearchApp/PDFDetailView.swift"
                var offenders: [String] = []
                for (name, text) in sources where name != home {
                    for raw in text.components(separatedBy: "\n") {
                        let line = raw.trimmingCharacters(in: .whitespaces)
                        guard line.contains("override func keyDown"),
                              !line.hasPrefix("//") else { continue }
                        offenders.append("\(name): \(line)")
                    }
                }
                try expectTrue(offenders.isEmpty,
                               "键盘事件只允许出现在 QuotePDFView 的 keyDown 覆盖内"
                               + "（其他键位统一使用 KeybindingRegistry）：\n  "
                               + offenders.joined(separator: "\n  "))
                let homeFile = sources.first { $0.name == home }
                let text = try expectNotNil(homeFile?.text)
                let count = text.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.contains("override func keyDown") && !$0.hasPrefix("//") }
                    .count
                try expectEqual(count, 1, "全仓唯一新增键盘事件入口（恰一处）")
            },

            // MARK: 守卫三条（AI 增强批）

            TestDesc(suite: "DesignGuard", name: "v710CoreNewFilesAreFoundationOnly") {
                let coreDir = repoRoot.appendingPathComponent("Sources/LiteratureCore")
                let newFiles = ["FoundationModelsTransport.swift", "RCSContextBuilder.swift",
                                "AICallLedger.swift", "SpeedReadPreset.swift", "ReviewSelfCheck.swift"]
                for file in newFiles {
                    let url = coreDir.appendingPathComponent(file)
                    let text = try expectNotNil(try? String(contentsOf: url, encoding: .utf8),
                                                "新 Core 文件应在位：\(file)")
                    for line in text.components(separatedBy: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("import ") else { continue }
                        try expectFalse(trimmed.contains("AppKit") || trimmed.contains("UIKit"),
                                        "\(file) 不得导入 AppKit/UIKit：\(trimmed)")
                    }
                }
            },

            TestDesc(suite: "DesignGuard", name: "foundationModelsImportStaysInSingleHost") {
                let sources = try allSources()
                var hosts: [String] = []
                for (name, text) in sources {
                    for line in text.components(separatedBy: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("import FoundationModels") {
                            hosts.append(name)
                        }
                    }
                }
                try expectEqual(Set(hosts), ["LiteratureCore/FoundationModelsTransport.swift"],
                                "FoundationModels import 只许一个宿主文件，实得：\(hosts)")
                try expectEqual(hosts.count, 1)
            },

            TestDesc(suite: "DesignGuard", name: "onDeviceTransportNeverTouchesURLSession") {
                let url = repoRoot.appendingPathComponent(
                    "Sources/LiteratureCore/FoundationModelsTransport.swift")
                let text = try expectNotNil(try? String(contentsOf: url, encoding: .utf8))
                let hits = text.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.contains("URLSession") }
                try expectTrue(hits.isEmpty,
                               "端上 transport 不得访问 URLSession（数据不出设备）：\n  "
                               + hits.joined(separator: "\n  "))
            },

            TestDesc(suite: "DesignGuard", name: "speedReadPresetContainsNoChatPaperText") {
                let url = repoRoot.appendingPathComponent(
                    "Sources/LiteratureCore/SpeedReadPreset.swift")
                let text = try expectNotNil(try? String(contentsOf: url, encoding: .utf8))
                let banned = ["research background", "past methods", "methodology",
                              "Please summarize the paper", "chat_arxiv"]
                for term in banned {
                    try expectFalse(text.lowercased().contains(term.lowercased()),
                                    "SpeedReadPreset 禁复制 ChatPaper 原文串（其许可证 CC BY-NC-ND 不允许复制）：\(term)")
                }
            },

            /// 综述 runner 不触批注库（采用只进内存与剪贴板，
            /// 不自动写批注；类型层面零引用）。
            TestDesc(suite: "DesignGuard", name: "reviewSelfCheckNeverTouchesAnnotationStores") {
                let url = repoRoot.appendingPathComponent(
                    "Sources/LiteratureCore/ReviewSelfCheck.swift")
                let text = try expectNotNil(try? String(contentsOf: url, encoding: .utf8))
                for banned in ["HighlightStore", "AnnotationBundle", "InkStrokesStore",
                               "AnnotationMergeEngine", "NSPasteboard"] {
                    try expectFalse(text.contains(banned),
                                    "ReviewSelfCheck 不得引用批注存储或剪贴板：\(banned)")
                }
            },

            // ── 管理批新增守卫──

            /// `.search` 旧 case 锁定：FavoritesStore.swift 源含
            /// `case search(query: String)` 字面（关联值改形即红）＋含
            /// `case smartSearch(query: String, filter: SearchFilter?)`（新 case 在位）。
            TestDesc(suite: "DesignGuard", name: "favoriteSearchCaseLockedAndSmartSearchAdded") {
                let url = repoRoot.appendingPathComponent(
                    "Sources/LiteratureCore/FavoritesStore.swift")
                let text = try expectNotNil(try? String(contentsOf: url, encoding: .utf8))
                try expectTrue(text.contains("case search(query: String)"),
                               ".search 的关联值必须保持 query: String")
                try expectTrue(
                    text.contains("case smartSearch(query: String, filter: SearchFilter?)"),
                    ".smartSearch 新 case 缺位")
            },

            /// 检索链零挂载：ClassificationRules.swift 只许 Foundation
            /// import 且不含 SearchNormalization 字样（归一化基准属检索链）。
            TestDesc(suite: "DesignGuard", name: "classificationRulesNeverTouchesSearchChain") {
                let url = repoRoot.appendingPathComponent(
                    "Sources/LiteratureCore/ClassificationRules.swift")
                let text = try expectNotNil(try? String(contentsOf: url, encoding: .utf8))
                for line in text.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("import ") else { continue }
                    try expectTrue(trimmed == "import Foundation",
                                   "ClassificationRules 违规 import（白名单：Foundation）：\(trimmed)")
                }
                let codeLines = text.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.hasPrefix("//") }
                try expectFalse(codeLines.contains { $0.contains("SearchNormalization") },
                                "ClassificationRules 不得依赖 SearchNormalization")
            },

            /// 烧录调用面唯一：全 Sources `PDFBurnExporter.export(` 调用点
            /// 恰 1 处（BookDetailView，用户显式按钮）——防自动/批量路径滋生
            ///（定义处与测试文件不在 Sources/ 扫描面内）。
            TestDesc(suite: "DesignGuard", name: "burnExportCallSiteStaysSingleton") {
                let sources = try allSources()
                var callSites: [String] = []
                for (name, text) in sources {
                    if text.contains("PDFBurnExporter.export(") {
                        callSites.append(name)
                    }
                }
                try expectEqual(Set(callSites), ["LiteratureSearchApp/BookDetailView.swift"],
                                "烧录导出调用点必须唯一（显式按钮），实得：\(callSites)")
            },

            /// CLI 不手拼深链：LiteratureSearchCLI.swift 源不含
            /// "literaturesearch://" 字面且必经 DeepLink（防双实现漂移）。
            TestDesc(suite: "DesignGuard", name: "cliNeverHandcraftsDeepLink") {
                let url = repoRoot.appendingPathComponent(
                    "Sources/literaturesearch-cli/LiteratureSearchCLI.swift")
                let text = try expectNotNil(try? String(contentsOf: url, encoding: .utf8))
                try expectFalse(text.contains("literaturesearch://"),
                                "CLI 禁手拼深链 URL（必经 DeepLink.build）")
                try expectTrue(text.contains("DeepLink.open(doc: doc, page: page, highlight: highlight).build()"),
                               "CLI 深链构造必须走 DeepLink.build 通道")
            },

            /// Bool guard 测试（回归断言）：PDFKit
            /// `write(to:)` 返回 Bool 不抛，默认写变换必须显式 guard 转
            /// 抛——否则写失败静默过闸、半文件经替换落到目标。
            TestDesc(suite: "DesignGuard", name: "burnExportDefaultTransformGuardsBool") {
                let url = repoRoot.appendingPathComponent(
                    "Sources/LiteratureCore/PDFBurnExport.swift")
                let text = try expectNotNil(try? String(contentsOf: url, encoding: .utf8))
                try expectTrue(
                    text.contains("guard document.write(to: target) else"),
                    "默认写变换必须 guard write(to:) Bool")
                try expectFalse(
                    text.contains("{ _ = $0.write(to: $1) }"),
                    "禁止吞 write(to:) Bool 的默认 transform（会吞掉写入失败）")
            },

            /// VisionKit 宿主唯一：`import VisionKit` 全仓仅
            /// TableCaptureView.swift 一处。
            TestDesc(suite: "DesignGuard", name: "visionKitImportStaysInSingleHost") {
                let sources = try allSources()
                var hosts: [String] = []
                for (name, text) in sources {
                    for line in text.components(separatedBy: "\n") {
                        if line.trimmingCharacters(in: .whitespaces).hasPrefix("import VisionKit") {
                            hosts.append(name)
                        }
                    }
                }
                try expectEqual(Set(hosts), ["LiteratureSearchApp/TableCaptureView.swift"],
                                "VisionKit import 只许一个宿主文件，实得：\(hosts)")
                try expectEqual(hosts.count, 1)
            },

            // ── 本机 API 守卫五条──

            /// Network 宿主唯一：`import Network` 全仓仅
            /// LocalAPIServer.swift 一处（App 层壳；Core 纯逻辑零网络 import）。
            TestDesc(suite: "DesignGuard", name: "networkImportStaysInSingleHost") {
                let sources = try allSources()
                var hosts: [String] = []
                for (name, text) in sources {
                    for line in text.components(separatedBy: "\n") {
                        if line.trimmingCharacters(in: .whitespaces).hasPrefix("import Network") {
                            hosts.append(name)
                        }
                    }
                }
                try expectEqual(Set(hosts), ["LiteratureSearchApp/LocalAPIServer.swift"],
                                "Network import 只许一个宿主文件，实得：\(hosts)")
                try expectEqual(hosts.count, 1)
            },

            /// 环回断言固定：LocalAPIServer.swift 源含 127.0.0.1 字面；
            /// 全 Sources 全网卡绑定字面（0.0.0.0）0 命中（全网卡绑定反例防回潮）。
            TestDesc(suite: "DesignGuard", name: "localAPIBindsLoopbackOnly") {
                let sources = try allSources()
                let server = sources.first { $0.name == "LiteratureSearchApp/LocalAPIServer.swift" }
                let text = try expectNotNil(server?.text, "LocalAPIServer.swift 应在位")
                try expectTrue(text.contains("127.0.0.1"),
                               "监听壳必须显式断言固定环回绑定（127.0.0.1 字面在案）")
                let offenders = sources.filter { $0.text.contains("0.0.0.0") }.map(\.name)
                try expectTrue(offenders.isEmpty,
                               "全 Sources 禁全网卡绑定字面（全网卡绑定反例）：\(offenders)")
            },

            /// 结构性只读：LocalAPI.swift 路由源不含注册 GET 之外的动词
            /// 字面（写动词出现即红——只读是结构不是约定；405 降级处理文案与动词
            /// 字面隔离，实现侧不写动词名）。补 PATCH（写动词
            /// 全列：POST/PUT/PATCH/DELETE）。 扩：MCP 桥同规
            TestDesc(suite: "DesignGuard", name: "localAPIRouteSourceHasNoWriteVerbLiterals") {
                let sources = try allSources()
                let guarded = ["LiteratureCore/LocalAPI.swift",
                               "LiteratureCore/MCPBridge.swift"]
                for name in guarded {
                    guard let file = sources.first(where: { $0.name == name }) else {
                        try failTest("守卫对象缺失（新文件应在册）：\(name)")
                        return
                    }
                    for verb in ["POST", "PUT", "PATCH", "DELETE"] {
                        try expectFalse(file.text.contains(verb),
                                        "\(name) 含写动词字面（结构性只读被破坏）：\(verb)")
                    }
                }
            },

            /// token 不进查询串：LocalAPI.swift／LocalAPIServer.swift 源
            /// 不含 "token=" 拼接字面（token 只收 Authorization 头，超 Joplin 条款）。
            /// 扩：MCP 桥同规（凭据走 _meta.authorization 进路由器，
            /// 永不进目标查询串）。
            TestDesc(suite: "DesignGuard", name: "localAPITokenNeverInQueryLiterals") {
                let sources = try allSources()
                let guarded = ["LiteratureCore/LocalAPI.swift",
                               "LiteratureSearchApp/LocalAPIServer.swift",
                               "LiteratureCore/MCPBridge.swift"]
                for name in guarded {
                    guard let file = sources.first(where: { $0.name == name }) else {
                        try failTest("守卫对象缺失（新文件应在册）：\(name)")
                        return
                    }
                    try expectFalse(file.text.contains("token="),
                                    "\(name) 禁 token 查询串拼接字面（token 只走 Authorization 头）")
                }
            },

            /// Core 新文件白名单 import（LocalAPI/MCPBridge/ReadingStatsStore
            /// 只许 Foundation/SQLite3；Network/AppKit/UIKit 出现即红——
            /// 起 MCP 桥同规）＋ReadingStatsStore 不挂 SearchNormalization
            /// （归一化基准属检索链）。
            TestDesc(suite: "DesignGuard", name: "v712CoreNewFilesAreFoundationOnly") {
                let sources = try allSources()
                let guarded = ["LiteratureCore/LocalAPI.swift",
                               "LiteratureCore/MCPBridge.swift",
                               "LiteratureCore/ReadingStatsStore.swift"]
                for name in guarded {
                    guard let file = sources.first(where: { $0.name == name }) else {
                        try failTest("守卫对象缺失（新 Core 文件应在册）：\(name)")
                        return
                    }
                    for raw in file.text.components(separatedBy: "\n") {
                        let trimmed = raw.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("import ") else { continue }
                        try expectTrue(trimmed == "import Foundation" || trimmed == "import SQLite3",
                                       "\(name) 违规 import（白名单：Foundation/SQLite3）：\(trimmed)")
                    }
                }
                let stats = sources.first { $0.name == "LiteratureCore/ReadingStatsStore.swift" }
                let statsText = try expectNotNil(stats?.text)
                let codeLines = statsText.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.hasPrefix("//") }
                try expectFalse(codeLines.contains { $0.contains("SearchNormalization") },
                                "ReadingStatsStore 零 SearchNormalization 挂载（归一化基准属检索链）")
            },

            // ── 新增守卫──

            /// 每日卡统计读失败必须记录——AppState 不得用
            /// `try? store.dailyTotals` 静默吞读错误（静默 nil＝假空态「今日暂无
            /// 阅读记录」），须 do/catch 走 logReadingStatsFailure（与写路径
            /// 同通道 stderr 记录）。足迹读
            /// 同规——readFootprints 禁 `try? store.footprints` 静默。
            TestDesc(suite: "DesignGuard", name: "readingStatsReadFailuresAreLogged") {
                let sources = try appSources()
                let appState = sources.first { $0.name == "AppState.swift" }
                let text = try expectNotNil(appState?.text, "AppState.swift 应在册")
                try expectFalse(text.contains("try? store.dailyTotals"),
                                "每日统计读失败禁止 try? 静默（读失败须留痕不假称无数据）")
                try expectFalse(text.contains("try? store.footprints"),
                                "足迹读失败禁止 try? 静默（徽标面降级须可观测）")
                try expectTrue(text.contains("logReadingStatsFailure"),
                               "统计读写失败同通道留痕（logReadingStatsFailure 应在册）")
            },

            /// 翻页喂点的统计行＋足迹 upsert
            /// 两写必须显式事务包裹（HighlightStore performWriteTransaction 同
            /// 款）——sessions 落库后 footprint 失败不得留下分裂行。
            TestDesc(suite: "DesignGuard", name: "readingStatsPageTurnWriteIsTransactional") {
                let sources = try allSources()
                let stats = sources.first { $0.name == "LiteratureCore/ReadingStatsStore.swift" }
                let text = try expectNotNil(stats?.text, "ReadingStatsStore.swift 应在册")
                try expectTrue(text.contains("BEGIN IMMEDIATE;") && text.contains("ROLLBACK;"),
                               "统计＋足迹两写须 BEGIN/ROLLBACK 事务包裹（同生共死）")
            },

            TestDesc(suite: "DesignGuard", name: "localAPIPeerCheckFailsClosed") {
                let sources = try allSources()
                let server = sources.first { $0.name == "LiteratureSearchApp/LocalAPIServer.swift" }
                let text = try expectNotNil(server?.text, "LocalAPIServer.swift 应在册")
                try expectTrue(
                    text.contains("guard case let .hostPort(host, _) = connection.endpoint, Self.isLoopback(host) else"),
                    "对端环回复核须 guard fail-closed 形（不可证明环回即拒收）")
                try expectFalse(text.contains("if case let .hostPort"),
                                "对端复核禁止 if-case 部分匹配放行形（对端复核断言）")
            },

            /// 本机 API 开关默认关（fail-closed 安全要求）——
            /// AppState 读 UserDefaults 前必须先判键存在性、缺省即 false；
            /// 新装首启/无显式开启永不自启（防默认开启回潮）。
            TestDesc(suite: "DesignGuard", name: "localAPIEnabledDefaultsOff") {
                let sources = try appSources()
                let appState = sources.first { $0.name == "AppState.swift" }
                let text = try expectNotNil(appState?.text, "AppState.swift 应在册")
                try expectTrue(
                    text.contains("object(forKey: \"localAPIEnabled\") != nil else { return false }"),
                    "localAPIEnabled 缺省必须 fail-closed 回 false（默认关安全约束）")
            },
        ]
    }
}

// MARK: - 无障碍守卫纯函数（DesignGuardSuite 扫真文件；
// A11yAuditTests 注入桩文本做正反例）

enum A11yGuards {
    /// (a) 动效门：含 `withAnimation(` / `.animation(`（非注释行）的文件，
    /// 同文件必须出现 `reduceMotion`（真门或豁免注记均可）。
    static func motionGateViolations(_ sources: [(String, String)]) -> [String] {
        sources.compactMap { name, text in
            let lines = text.components(separatedBy: "\n")
            let hasAnimationCall = lines.contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { return false }
                return trimmed.contains("withAnimation(") || trimmed.contains(".animation(")
            }
            guard hasAnimationCall, !text.contains("reduceMotion") else { return nil }
            return name
        }
    }

    /// (b) 对比度：DesignSystem.swift 必须含 `colorSchemeContrast`。
    static func contrastGateViolations(_ sources: [(String, String)]) -> [String] {
        let ds = sources.first { $0.0 == "DesignSystem.swift" }
        guard let ds else { return ["DesignSystem.swift"] }
        return ds.1.contains("colorSchemeContrast") ? [] : ["DesignSystem.swift"]
    }

    /// 视图文件清单（含 `: View {` 的文件）。
    static func viewFileNames(_ sources: [(String, String)]) -> [String] {
        sources.filter { $0.1.contains(": View {") }.map(\.0).sorted()
    }
}
