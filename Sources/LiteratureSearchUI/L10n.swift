import Foundation

/// UI strings (zh-CN) kept in one table, deliberately separated from any
/// explanatory text returned by the core. The UI never embeds conclusions
/// about model identity — the model name shown is exactly what the user
/// configured, or "未配置". Lives in the importable UI-logic module so both
/// the app and the synthetic test suite share the exact same strings.
/// 注：本文件禁 import LiteratureCore——iOS 单模块直编形态下 UI 与 Core 源
/// 并入同一 target（iOSCompileGate 基准），同模块互 import 即挂 iOS 门。
public enum L10n {
    public static let appTitle = "PinCite"
    public static let chooseFolder = "选择文献目录…"
    public static let startIndexing = "开始索引"
    public static let cancelIndexing = "取消索引"
    public static let indexingStatus = "索引中…"
    public static let searchPlaceholder = "搜索（支持中文子串与英文，空格分隔多个关键词）"
    public static let search = "搜索"
    public static let history = "搜索历史"

    public static let labelUnknown = "页码标签未知"
    public static let printedPageUnknown = "印刷页码未知"

    public static let aiSection = "AI 助手（可选，默认未配置）"
    public static let aiServiceURL = "服务地址"
    public static let aiModel = "模型标识（由你填写）"
    public static let aiAPIKey = "API 密钥（仅保存在内存，不落盘）"
    public static let aiConfigure = "保存配置"
    public static let aiUnconfigured = "AI 未配置：不会发出任何网络请求"
    public static let aiConfirmSend = "确认发送（仅此一次）"
    public static let aiCancelSend = "取消"
    public static let aiPreviewTitle = "将要发送的内容预览"

    public static let staleReference = "原件内容已变化（指纹不匹配），已拒绝打开。若这是 App 升级后首次出现，请重启 App 重试；仍失败则对该书重新索引一次"
    public static let zeroRequestsNote = "未确认时不发出任何请求"

    // MARK: OCR 配对（显式清单导入）

    public static let ocrSection = "OCR 配对（显式清单导入；不自动扫描、不自动配对）"
    public static let chooseOCRManifest = "选择 OCR 配对清单…"
    public static let chooseOriginalRoot = "选择原件根目录…"
    public static let chooseOCRRoot = "选择 OCR 根目录…"
    public static let importOCRPairs = "导入 OCR 配对"
    public static let verifyOCRPairs = "复查已登记配对"
    public static let cancelOCRImport = "取消导入"
    public static let ocrNotSelected = "未选择 OCR 配对清单"
    public static let openOriginalPage = "打开原件原页"
    public static let backToOCRView = "返回 OCR 页视图"
    public static let closePDF = "关闭"

    public static let sourceNative = "原文"
    public static let sourceOCR = "OCR"
    public static let ocrFilePage = "OCR 文件页"
    public static let coverageRefresh = "刷新覆盖统计"

    // MARK: 跨设备快照（白名单导出 / 仅历史导入）

    public static let syncSection = "跨设备快照（白名单字段：无路径、无密钥、无原文）"
    public static let syncExport = "导出快照…"
    public static let syncImport = "导入快照…"
    public static let syncCancelled = "已取消"
    public static let syncExportedOK = "快照已导出"
    public static let syncExportFailed = "导出失败: "
    public static let syncImportedOK = "快照已导入"
    public static let syncImportFailed = "导入失败: "

    // MARK: WebDAV 同步（1a：远端文献下载进本库；凭据只进本机钥匙串）

    public static let webdavSection = "WebDAV 同步（远端文献下载进本库）"
    public static let webdavPanelNote = "从 WebDAV 把远端文献拉到本地。密码仅存本机钥匙串，不随快照同步、不落盘；点击任一按钮即保存当前配置。"
    public static let webdavServerURL = "服务器 URL（如 https://dav.example.com/webdav）"
    public static let webdavUsername = "用户名"
    public static let webdavPassword = "密码（仅存本机钥匙串）"
    public static let webdavRemoteDir = "远端目录（如 /Books）"
    public static let webdavTestConnection = "连接测试"
    public static let webdavPreviewSync = "预览同步（dry-run）"
    public static let webdavSyncNow = "立即同步"
    public static let webdavWorking = "正在连接远端…"
    public static let webdavInvalidURL = "服务器地址无效：必须是 HTTPS（Basic 凭据不得走明文 HTTP）"
    public static let webdavCredentialsMissing = "请先填写服务器 URL、用户名与密码"
    public static let webdavConfigSaved = "配置已保存（密码仅存本机钥匙串）· "
    public static let webdavSaveFailedPrefix = "配置保存失败: "
    public static func webdavTestOK(_ entries: Int) -> String {
        "连接成功：远端目录共 \(entries) 个条目"
    }
    public static let webdavTestFailedPrefix = "连接失败: "
    public static func webdavPreviewOK(_ count: Int, _ size: String) -> String {
        "将下载 \(count) 个文件，共 \(size)（预演：未下载、未写账本）"
    }
    public static let webdavPreviewFailedPrefix = "预览失败: "
    public static func webdavSyncOK(_ downloaded: Int, _ skipped: Int, _ failed: Int) -> String {
        "同步完成：新增 \(downloaded) · 跳过 \(skipped) · 失败 \(failed)"
    }
    public static let webdavSyncFailedPrefix = "同步失败: "
    public static func webdavLocalTarget(_ name: String) -> String {
        "下载落点：Application Support/LiteratureSearch/\(name)（新文件进检索需对该目录再跑一次索引）"
    }

    // MARK: WebDAV 索引上传（Mac 上传索引快照，供 iOS 只读副本拉取）

    public static let webdavUploadGroupTitle = "索引上传"
    public static let webdavUploadIndex = "上传索引到 WebDAV"
    public static let webdavAutoUploadToggle = "索引重建后自动上传"
    public static let webdavCleanupToggle = "上传后清理未引用旧快照（保留最近 2 份；单次至多删 8 个）"
    public static let webdavUploadInProgress = "正在生成索引快照并上传…（大库首次生成需数分钟）"
    /// 安全约束：sha256 仅表示完整性校验（防损坏与传输错误）。
    public static let webdavUploadPrivacyNote = "上传会发送完整数据库快照，其中可能包含本机文件路径、提取的全文和笔记。WebDAV 服务商可读取快照及清单，HTTPS 只保护传输过程。"
    public static let webdavUploadAuditTitle = "最近操作（至多保留 5 条）"
    public static let webdavUploadAuditEmpty = "尚无上传/删除记录"
    public static func webdavUploadOK(_ volumes: Int, _ skipped: Int, _ size: String, _ seconds: String) -> String {
        "上传完成：\(volumes) 个分卷（幂等跳过 \(skipped)）· 共 \(size) · 用时 \(seconds)"
    }
    public static let webdavUploadFailedPrefix = "索引上传失败: "
    public static let webdavUploadCleanupFailedPrefix = "（上传已提交；旧快照清理失败: "
    public static let webdavUploadCleanupFailedSuffix = "）"
    public static func webdavUploadAuditLine(_ time: String, _ detail: String) -> String {
        "\(time) · \(detail)"
    }
    public static func webdavUploadAuditUpload(_ volumes: Int, _ size: String, _ duration: String, _ result: String) -> String {
        "上传 \(volumes) 个分卷 · 共 \(size) · 用时 \(duration) · \(result)"
    }
    public static func webdavUploadAuditCleanup(_ name: String, _ result: String) -> String {
        "清理旧快照 \(name) · \(result)"
    }
    public static func webdavUploadAuditFailed(_ detail: String) -> String {
        "上传失败 · \(detail)"
    }
    public static func webdavUploadDurationSeconds(_ value: Double) -> String {
        String(format: "%.1f 秒", value)
    }

    // MARK: AI 配置探活（入册：探活 prompt 原为视图内硬编码，收进 L10n）

    public static let aiProfilesProbePrompt = "请回复：连通正常"

    // MARK: 三栏导航（前端重构；纯字符串——本文件被 iOS/watch/Widget target 直接编译）

    public static let navSearch = "检索"
    public static let navHistory = "历史"
    public static let navCoverage = "覆盖"
    public static let navLibrary = "书库与导入"
    public static let navMenu = "导航"
    public static let focusSearch = "聚焦搜索"
    public static let closeDetail = "关闭详情"

    // MARK: 三栏外壳（列宽不联动 + 三栏独立收起）

    public static let columnSidebarTooltip = "侧栏（⌘1）"
    public static let columnResultsTooltip = "结果列表（⌘2）"
    public static let columnDetailTooltip = "原文栏（⌘3）"
    public static let columnDividerAccessibility = "栏宽分隔条（拖动调宽，双击复位）"
    public static func bookHitsTruncated(_ limit: Int) -> String {
        "本书命中超过 \(limit) 页，已显示前 \(limit) 页（可在「书库与导入 → 引用与检索」调高上限）"
    }
    public static let prevHit = "上一处"
    public static let nextHit = "下一处"
    public static let copyCitationFaxue = "复制引用（中文引注手册体例）"
    public static let copyCitationZGF = "复制引用（中文期刊体例 A）"
    public static let docSearchPlaceholder = "在本文内搜索（不截断）"
    public static let docSearchRun = "搜索本文"
    /// L10n 内部拼接件：被同文件 docSearchOccurrence 复用，非零引用（不可按外部引用删）。
    public static let docSearchHitUnit = "处"
    public static let docSearchNoMatch = "本文无此内容"
    // MARK: AI 升级（PaperQA2 式综合 / 快捷指令模板）

    public static let quickTranslateZH = "翻译为中文"
    public static let quickTranslateEN = "翻译为英文"
    public static let quickSummarize = "总结此片段"
    public static let quickExplain = "解释此片段"
    public static let addToSynthesis = "加入综合证据"
    public static let synthesisButton = "综合所选证据"
    public static let synthesisNeedsTwo = "综合至少需要 2 条证据"
    // AI 可取消 + 过程折叠
    public static let aiStopGenerating = "停止"
    public static let aiSendCancelled = "已停止：可直接重新发送"
    public static let aiAlreadySending = "已有请求进行中：请先停止或等待完成"
    public static func synthesisEvidenceCollapsed(_ count: Int) -> String {
        "证据列表（共 \(count) 条，展开逐条查看）"
    }
    public static let synthesisEvidenceExpanded = "收起证据列表"
    public static let storageSection = "存储位置"
    public static let storageIndexDBLabel = "索引库"
    public static let storageIndexDBNote = "索引库位置为只读展示；迁移涉及库重建，留待后续版本评估"
    public static let storageExportDirLabel = "导出目录"
    public static let storageChooseExportDir = "更改导出目录"
    public static let librarySection = "书库"
    public static let noRootSelected = "未选择目录"
    public static let detailPlaceholder = "在左侧结果中选择一条命中查看原文（只读；OCR 命中默认显示 OCR 页）"
    public static let detailPlaceholderEmpty = "尚无选中结果"

    // MARK: 空态引导（三步开始）

    public static let onboardingTitle = "三步开始检索"
    public static let onboardingStep1 = "选择文献目录"
    public static let onboardingStep1Hint = "选择存放 PDF 的文件夹；不会扫描未选择的目录"
    public static let onboardingStep2 = "建立索引"
    public static let onboardingStep2Hint = "提取文字层并建立全文索引；只写索引库，不改动原件"
    public static let onboardingStep3 = "输入一个词，回车"
    public static let onboardingStep3Hint = "检索框在上方；零命中时会逐书说明原因"

    // MARK: 检索页

    public static let recentSearches = "最近检索"
    public static let filterLabel = "筛选"
    public static let filterAuthor = "作者包含"
    public static let filterVersion = "版本包含"
    public static let filterLanguage = "语言"
    public static let filterUnknownNote = "未知字段不参与匹配"
    public static let sourceFilterAll = "来源: 全部"
    public static let domainAll = "类型: 全部"
    public static let domainBook = "著作"
    public static let domainPaper = "论文"
    public static let sourceFilterNative = "来源: 原文"
    public static let sourceFilterOCR = "来源: OCR"
    public static let physicalPageTrack = "物理页"
    public static let printedPageTrack = "印刷页"
    public static let pageLabelTrack = "标签"
    public static let matchCountSuffix = "处"
    public static let pageUnit = "页"
    public static let booksUnit = "本"
    public static let resultSummaryHits = "共命中"
    public static let viewingOriginal = "正在查看原件（只读）"
    public static let askAI = "问 AI"
    public static let addToCompare = "加入对比"
    public static let buildComparePreviews = "生成对比预览"
    public static let compareSectionTitle = "多片段对比（每片段独立确认后发送）"
    public static let aiQuestionPlaceholder = "问题（可空，默认：解释选中片段）"
    public static let metadataNote = "元数据（仅写入索引，不改动原件；未知不猜）"
    public static let metadataOpenButton = "编辑元数据"
    public static let aiSectionTitle = "AI 助手"
    public static let aiSectionExpandHint = "展开后可提问、对比与综合；发送前始终逐次确认"
    public static let focusReadingEnter = "专注阅读"
    public static let focusReadingExit = "退出专注阅读"
    public static let zeroHitCoverageLink = "在「覆盖」页查看全貌"
    public static let historyPageTitle = "检索历史"
    public static let historyLimitNote = "最多保留 20 条"
    public static let clearHistory = "清空历史"
    public static let historyCleared = "已清空"
    public static let historyEmpty = "尚无检索历史"
    public static let coverageSectionTitle = "覆盖统计"
    public static let coverageBooksLine = "已索引书目"
    public static let coveragePagesLine = "页面"
    public static let coverageNoTextLine = "无文本页（未OCR，保持无文本）"
    public static let coverageErrorBooksLine = "错误书目"
    public static let coverageNotBuilt = "尚未建立索引"
    public static let coverageLastRunPrefix = "上次运行："
    public static let coveragePerBookDetail = "分类明细（逐书）"

    // MARK: 视觉打磨补充（纯字符串常量，供空态构图复用）

    public static let emptySearchTitle = "检索你的文献库"
    public static let emptySearchDetail = "支持中文子串与英文，空格分隔多个关键词；零命中时会逐书说明原因"
    public static let historyEmptyDetail = "执行一次检索后，这里会自动记录最近 20 条"
    public static let onboardingWelcome = "一个安静的文献检索工具：只读检索，不改动原件"

    // MARK: 引用升级与书目详情

    public static let citationStyleLabel = "引注体例"
    public static let bookHitsLimitLabel = "单书命中加载上限"
    public static let bookHitsLimitUnlimited = "不设限（整本书全部命中）"
    public static let copyBookCitationCurrent = "复制书目引注（当前体例）"
    public static let copyAllBookCitations = "复制全部书目引注"
    public static func copyBookHitsCitationsLoaded(_ n: Int) -> String {
        "复制本书命中引注（已加载 \(n) 条）"
    }
    public static let bibliographyStyleNote = "两体例著作类形态一致；批量书目引注同形"

    // MARK: PDF 选区右键引用
    public static let menuQuotationFaxue = "复制直接引文（中文引注手册体例）"
    public static let menuQuotationZGF = "复制直接引文（中文期刊体例 A）"
    public static let menuSourceCitation = "复制出处（书名，第N页）"
    public static let menuCopySelectedText = "复制选中文本"
    public static func hitsBadgeLoaded(actual: Int, candidate: Int, total: Int) -> String {
        actual == candidate
            ? "命中 \(actual) 页 / 全书 \(total) 页"
            : "命中 \(actual) 页（候选 \(candidate)）/ 全书 \(total) 页"
    }
    public static let copyBibtex = "复制 BibTeX"
    public static let copyAllBibtex = "复制全部书目 BibTeX"
    public static let citationSettingsSection = "引用与检索"
    public static let booksSection = "书目（全部）"
    public static let searchBooksPlaceholder = "按文件名 / 标题 / 作者筛选"
    public static let bookDetailTitle = "书目详情"
    public static let bookDetailOpen = "书目详情"
    public static let metaFieldTitle = "标题"
    public static let metaFieldAuthor = "作者"
    public static let metaFieldVersion = "版本"
    public static let metaFieldLanguage = "语言"
    public static let metaSourceLabel = "元数据来源"
    public static let bookFileFacts = "文件与索引"
    public static let bookFactFileName = "文件名"
    public static let bookFactSize = "大小"
    public static let bookFactPhysicalPages = "物理页"
    public static let bookFactIndexedAt = "索引时间"
    public static let bookFactStatus = "状态"
    public static let bookStatusOK = "正常"
    public static let bookFactUnknown = "未知"
    public static let bookDetailMissing = "书目不存在或索引不可读"
    public static let bibtexNote = "BibTeX 仅含真实存在的字段；缺失字段省略，绝不编造；批量导出时重复键自动加序号"
    public static func bookCoverageFull(pagesWithText: Int, indexedPages: Int) -> String {
        "全文可检索（\(pagesWithText)/\(indexedPages) 页有文字层）"
    }
    public static func bookCoveragePartial(pagesWithText: Int, indexedPages: Int) -> String {
        "部分可检索（\(pagesWithText)/\(indexedPages) 页有文字层）"
    }
    public static let bookCoverageNeedsOCR = "待 OCR（0 页有文字层，整本暂不可检索）"
    public static let bookCoverageUnknown = "无法评估"
    public static let bookCoverageLine = "文字层覆盖"
    public static let bookSaveMeta = "保存到索引"

    // MARK: 主题与阅读态（设计系统；纯字符串）

    public static let appearanceSection = "外观"
    public static let themeSystem = "跟随系统"
    public static let themeGraphite = "墨灰"
    public static let themeObsidian = "玄青"
    public static let readingSerifLabel = "阅读正文使用宋体（Songti SC）"
    public static let readingSerifNote = "仅作用于命中摘要与详情正文；界面控件保持黑体"

    // MARK: 无障碍标签（图标按钮；浮层导航条）

    public static let bookDetailInfoHint = "书目详情"
    public static let closePDFButton = "关闭 PDF"
    public static let prevMatchButton = "上一处页内命中"
    public static let nextMatchButton = "下一处页内命中"
    public static let docSearchPrevButton = "上一处本文搜索结果"
    public static let docSearchNextButton = "下一处本文搜索结果"


    public static let clearFilter = "清除过滤"
    public static let filterActiveHint = "正在按此分类过滤下方明细"

    // MARK: 详情栏守卫文案入册（逐字迁移自原硬编码；判定逻辑零改动）

    public static func viewingOriginalPage(_ physicalPage: Int) -> String {
        "正在查看：原件第 \(physicalPage) 物理页（无高亮——命中坐标属于 OCR 文件）"
    }
    public static func viewingOCRPage(_ page: Int) -> String {
        "正在查看：OCR 文件第 \(page) 页（高亮仅在 OCR 页上）"
    }
    public static let pairingDenied = "该 OCR 命中缺少配对信息（OCR 文件/页/指纹缺失），已拒绝显示"

    // MARK: 浮层导航条计数文案入册（打磨；逐字迁移自 ReadingChrome 硬编码）

    public static func docSearchOccurrence(_ current: Int, _ total: Int) -> String {
        "第 \(current)/\(total) \(docSearchHitUnit)"
    }
    public static func pageMatchCounter(_ current: Int, _ total: Int) -> String {
        "命中 \(current)/\(total)"
    }
    public static let importSidecar = "导入 sidecar…"

    // MARK: 检索反馈（纯字符串）

    public static let searchingStatus = "检索中…"
    public static let pdfLoading = "正在打开原文…"

    // MARK: 结果列表

    public static let collapseAll = "收合全部"
    public static func hitsBadgeCollapsed(actual: Int, total: Int) -> String {
        "命中 \(actual) 页 / 全书 \(total) 页"
    }

    // MARK: 浮层导航条（纯字符串）

    public static let showReadingChrome = "显示阅读工具栏"
    public static let shortcutPrevMatch = "⇧⌘G"
    public static let shortcutNextMatch = "⌘G"

    // MARK: AI 面板（纯字符串）

    public static let copyAnswer = "复制回答"


    public static let settingsGroupLabel = "设置分组"
    public static let settingsGroupAppearance = "外观"
    public static let settingsGroupLibrary = "书库与书目"
    public static let settingsGroupCitationOCR = "引用·检索与 OCR"
    public static let settingsGroupAISync = "AI 与同步"
    public static let bookHitsLimitNote = "调高后「本书全部」可一次加载更多命中；截断提示始终如实显示"
    /// L10n 内部拼接件：被同文件 ocrOriginalRootStatus／ocrOCRRootStatus 复用，非零引用（不可按外部引用删）。
    public static let notSelected = "未选择"
    public static func ocrManifestStatus(_ name: String, pairs: Int?) -> String {
        let base = "清单: \(name)"
        if let pairs { return base + "（\(pairs) 对）" }
        return base
    }
    public static func ocrOriginalRootStatus(_ name: String?) -> String {
        "原件根: \(name ?? notSelected)"
    }
    public static func ocrOCRRootStatus(_ name: String?) -> String {
        "OCR根: \(name ?? notSelected)"
    }
    public static let ocrImportingStatus = "导入中…"
    public static func ocrManifestParseFailed(_ error: String) -> String {
        "清单解析失败: \(error)"
    }
    public static let syncSnapshotNote = "导出仅含白名单元数据；导入只合并检索历史。无云同步（个人签名限制，云侧仅协议占位）。"

    // MARK: 逐视图打磨（纯字符串）

    public static let zeroHitRetry = "修改关键词"

    // MARK: 错误恢复（纯字符串）

    public static let indexRetryTitle = "建立索引时出现问题"
    public static let indexRetryButton = "重试建立索引"
    public static let indexRetryNote = "原件未被改动；可重试或更换文献目录"

    // MARK: 视觉打磨（纯字符串）

    public static let settingsGroupAbout = "关于"
    public static let aboutTagline = "PinCite · 本地优先的书房式文献精查工具"

    // MARK: 每日一句（widget slice；纯字符串；Widget 侧文案随
    // RecentSearches 先例内联在 app/Widget，widget target 不链接 UI 库）

    public static let navQuote = "每日一句"
    public static let quotePreparing = "正在准备今日摘录…"
    public static let quoteEmptyTitle = "今日暂无摘录"
    public static let quoteEmptyDetail = "建立索引后，应用会在后台从文献库抽取当日的法学长句"
    /// 出处行：引注复用 CitationFormatter.bookCitation + 页码（与 CLI 引注串同形）。
    public static func quoteCitation(_ book: String, page: Int) -> String {
        "\(book)，第\(page)页"
    }
    public static let quoteOpenBook = "打开原书此页"
    // 三按钮：翻译 / 解释 / 语法拆解，各走既有 AI 确认门
    // （openGuard → 零 I/O 预览 → 逐次确认发送，未确认前零请求），仅预填 prompt 不同。
    public static let quoteTranslate = "翻译"
    public static let quoteExplain = "解释"
    public static let quoteGrammar = "语法拆解"
    /// 翻译预填 prompt（原文段落由 selection 上下文携带）。
    public static let quoteAITranslatePrompt = "将以下英文段落翻译为中文，保留术语原文："
    /// 解释预填 prompt。
    public static let quoteAIExplainPrompt = "解释以下段落的核心论点与学术背景："
    /// 语法拆解预填 prompt。
    public static let quoteAIGrammarPrompt = "对以下英文段落做语法结构拆解（主句/从句/修饰关系），并给出关键术语释义："
    public static let quoteAlternativesTitle = "备选摘录"
    public static let quoteBookMissing = "该摘录对应的书目或页面已不在索引中，无法打开原书"

    // MARK: 每日卡阅读统计＋整卡朗读（纯字符串）

    public static let dailyStatsTitle = "今日阅读"
    /// 统计行：分钟/翻页次数。分钟基准与 Core DailyCardComposer.minutesText
    /// 同规（<10 保一位小数、≥10 四舍五入取整）——iOS 单模块直编形态下 UI
    /// 不能 import Core，两处按同规各写一份，parity 由合成测试断言固定防漂移。
    public static func dailyStatsLine(minutes: Double, pages: Int) -> String {
        let oneDecimalOrWhole: String
        if minutes >= 10 {
            oneDecimalOrWhole = String(format: "%.0f", minutes.rounded(.toNearestOrAwayFromZero))
        } else {
            let oneDecimal = String(format: "%.1f", minutes)
            oneDecimalOrWhole = oneDecimal.hasSuffix(".0") ? String(oneDecimal.dropLast(2)) : oneDecimal
        }
        return "\(oneDecimalOrWhole) 分钟 · 翻页 \(pages) 次"
    }
    public static let dailyStatsEmpty = "今日暂无阅读记录"
    public static let dailyCardSpeak = "朗读今日卡片"
    public static let dailyCardStop = "停止朗读"

    // MARK: 足迹图例（如实命名：圆点＝翻到即记，不称「已精读」）

    public static let overviewFootprintLegend = "圆点＝已翻到的页"

    // MARK: 本机只读 API（纯字符串）

    public static let localAPISection = "本机 API"
    public static let localAPIEnable = "启用本机只读接口"
    public static let localAPIRunning = "运行中"
    public static let localAPIStopped = "已停止"
    public static let localAPIPortLabel = "监听地址"
    public static let localAPITokenLabel = "访问令牌"
    public static let localAPICopy = "复制令牌"
    public static let localAPICopied = "已复制"
    public static let localAPIAudit = "最近请求"
    public static let localAPIAuditEmpty = "暂无请求记录"
    /// 说明行：默认关/仅本机/token 生命周期（代价＝脚本每次启动需重读）。
    public static let localAPIExplain = "默认关闭；仅本机 127.0.0.1 可访问；每次重启 App 后令牌更换，脚本需从本页重新复制。令牌只随 Authorization 头传递。"
    public static let localAPIStoreUnavailable = "索引库未就绪，本机接口未能启动"
    public static let localAPIStartFailedPrefix = "启动失败："
    public static let localAPIInvalidPort = "启动失败：端口值非法"
    /// 审计行：端点/状态码/耗时/字节数（不含查询正文不含令牌）。
    public static func localAPIAuditLine(_ endpoint: String, status: Int, milliseconds: Double, bytes: Int) -> String {
        String(format: "%@ · %d · %.1f ms · %d B", endpoint, status, milliseconds, bytes)
    }

    // MARK: - AI Chat

    public static let aiClearChat = "清空对话"
    public static let aiCitationNone = "（本次回答未附可核验引用）"
    public static func aiCitationLine(_ fileName: String, _ page: Int) -> String {
        "《\(fileName)》物理页 \(page)"
    }
    public static let aiChatUserBubble = "我的提问"
    public static let aiChatAssistantBubble = "AI 回答"

    // MARK: - Highlights

    public static let menuAddHighlight = "添加高亮"
    public static let menuHighlightYellow = "黄色高亮"
    public static let menuHighlightGreen = "绿色高亮"
    public static let menuHighlightBlue = "蓝色高亮"
    public static let menuHighlightRed = "红色高亮"
    public static let menuAddPageFavorite = "添加到收藏"
    public static let highlightsButton = "我的高亮"
    public static let highlightsPopoverTitle = "本书高亮"
    public static let highlightsEmpty = "本书还没有高亮；在原文里选中文字后右键即可添加"
    public static func highlightsPageLabel(_ page: Int) -> String {
        "第 \(page) 页"
    }
    public static let highlightsNotePlaceholder = "备注（回车保存）"
    public static let highlightsDeleteConfirmTitle = "删除此高亮？"
    public static let highlightsDeleteConfirmMessage = "删除后不可恢复。"
    public static let highlightsUpdated = "已更新"
    public static let highlightsColorAccessibility = "高亮颜色"

    // MARK: - Favorites

    public static let navFavorites = "收藏"
    public static let favoriteBook = "收藏此书"
    public static let favoritePage = "收藏此页"
    public static let favoriteQuote = "收藏此句"
    public static let favoriteSearch = "收藏此检索式"
    public static let favoriteAddedBook = "已收藏此书"
    public static let favoriteAddedPage = "已收藏此页"
    public static let favoriteAddedQuote = "已收藏此句"
    public static let favoriteAddedSearch = "已收藏此检索式"
    public static let favoriteAddFailed = "收藏失败"
    public static let favoritesEmpty = "还没有收藏；在检索结果、每日一句或原文选区菜单里都可以收藏"
    public static let favoritesFilterPlaceholder = "筛选收藏（标题 / 文件 / 内容 / 分类 / 标签）"
    public static let favoritesModeAll = "全部"
    public static let favoritesModeCategories = "分类"
    public static let favoritesModeTags = "标签"
    public static let favoritesUncategorized = "未分类"
    public static let favoritesOrganize = "整理"
    public static let favoritesOrganizeDone = "完成"
    public static let favoritesNewCategoryPlaceholder = "新分类（留空则用所选分类）"
    public static let favoritesCategoryApply = "设为分类"
    public static let favoritesTagsPlaceholder = "加标签（逗号分隔）"
    public static let favoritesTagsApply = "加标签"
    public static let favoritesOpenBook = "打开"
    public static let favoritesJumpToPage = "跳原文"
    public static let favoritesCopyCitation = "复制引注"
    public static let favoritesRerunSearch = "重跑此检索"
    public static let actionDelete = "删除"
    public static func favoritesPageLine(_ page: Int) -> String {
        "第 \(page) 页"
    }

    // MARK: - 智能收藏（动态集合：存条件，打开现算）

    public static let favoriteSearchSmart = "存为智能集合"
    public static let favoriteAddedSmartSearch = "已存为智能集合（打开时按当前库现算）"
    /// 条件摘要（副标题；空条件 = 只按查询串）。
    public static func smartCollectionSummary(_ conditions: String) -> String {
        conditions.isEmpty ? "智能集合（无过滤条件）" : "智能集合 · \(conditions)"
    }
    public static func smartCollectionCondAuthor(_ a: String) -> String { "作者含 \(a)" }
    public static func smartCollectionCondVersion(_ v: String) -> String { "版本含 \(v)" }
    public static func smartCollectionCondLanguage(_ l: String) -> String { "语言 \(l)" }
    public static let smartCollectionCondPaper = "仅论文"
    public static let smartCollectionCondBook = "仅著作"
    /// 表格圈选错误（非 UI 文案面也走 L10n——l10n 门零硬编码）。
    public static let tableCaptureRenderFailed = "页位图渲染失败"
    public static let tableCaptureNoContent = "圈内无可识别内容"

    // MARK: - 自动归类（设置页区块）

    public static let classificationSection = "自动归类"
    public static let classificationHint = "规则按顺序匹配书名/作者/目录，先中先得；入库批末与「立即归类」时执行。未知（空缺）字段不参与匹配、不计为命中。"
    public static let classificationRunNow = "立即归类"
    public static let classificationAddRule = "添加规则"
    public static let classificationNamePlaceholder = "规则名"
    public static let classificationMatchPlaceholder = "匹配文本（any=空格分词；exact=title=X 或 author=X；prefix_dir=/目录/）"
    public static let classificationCategoryPlaceholder = "目标分类"
    public static let classificationEmpty = "还没有规则"
    public static let classificationMoveUp = "上移"
    public static let classificationMoveDown = "下移"
    public static func classificationStatus(_ rules: Int, _ classified: Int, _ unclassified: Int) -> String {
        "\(rules) 条规则 · \(classified) 书已归类 · \(unclassified) 未归类"
    }
    public static func classificationResult(_ classified: Int, _ unclassified: Int, _ skipped: Int) -> String {
        "已归类 \(classified) · 未归类 \(unclassified) · 跳过 \(skipped)"
    }
    public static let classificationFailed = "归类失败"

    // MARK: - 表格圈选→拷贝 TSV

    public static let tableCopyAction = "拷贝表格 TSV"
    public static func tableCopiedTextLayer(_ rows: Int) -> String {
        "已拷贝表格 TSV（\(rows) 行，来源：文字层）"
    }
    public static let tableCopiedImageFallback = "已拷贝识别文本（图像识别：无表格结构，未做列对齐）"
    public static let tableCopyFailed = "表格识别失败：圈内无可识别内容"
    public static let tableImageFallbackAction = "识别本页文本（图像识别）"

    // MARK: - 深链定位（open / collection）

    public static let deepLinkBookMissing = "深链指向的书不在库中"
    public static let deepLinkPageMissing = "深链指向的页不在该书中"
    public static let deepLinkCollectionMissing = "深链指向的收藏行不在了"
    /// open 深链 hl 指向的批注行不在（显式提示不静默）。
    public static let deepLinkHighlightMissing = "深链指向的批注行不在了"

    // MARK: - 命令面板（纯字符串）

    public static let paletteTitle = "命令面板"
    public static let palettePlaceholder = "输入以过滤命令…"
    public static let paletteEmpty = "无匹配命令"
    public static let paletteCmdFocusSearch = "聚焦搜索"
    public static let paletteCmdFocusReading = "切换专注阅读"
    public static let paletteCmdTheme = "轮换主题（跟随系统 → 墨灰 → 玄青）"
    public static let paletteCmdLibrary = "前往书库与导入"
    public static let paletteCmdCoverage = "前往覆盖统计"
    public static let paletteCmdHistory = "前往检索历史"
    public static let paletteCmdQuote = "前往每日一句"
    public static let paletteCmdFavorites = "前往收藏"

    // MARK: - 前端批（高亮导出 / 划词翻译 / TTS / 缩略图栏）

    public static let highlightsExportButton = "导出 Markdown"
    public static let highlightsExportFailed = "导出失败"
    public static func translatePromptZH(_ text: String) -> String {
        "将以下文本翻译为中文：\n\(text)"
    }
    public static func translatePromptEN(_ text: String) -> String {
        "将以下文本翻译为英文：\n\(text)"
    }
    public static let ttsSpeak = "朗读此页"
    public static let ttsStop = "停止"
    public static let ttsSpeaking = "朗读中…"
    public static let thumbnailsToggle = "缩略图"

    // MARK: - 阅读功能（目录侧栏/常驻阅读位置/双页对开）

    public static let outlineToggle = "目录"
    public static let outlineEmptyLabel = "（无标题）"
    /// 自动目录回退：侧栏小字标注来源（原生书签书不显示）。
    public static let outlineAutoGenerated = "自动目录"

    // AI 配置：任务用途路由显示名（AIProfilesStore.AIPurpose）
    public static let purposeTranslate = "翻译为中文/英文"
    public static let purposeSummarize = "总结此片段"
    public static let purposeExplain = "解释此片段"
    public static let purposeGrammar = "语法拆解"
    public static let purposeDailyQuote = "每日一句解析"
    public static let purposeFreeChat = "自由问答"
    public static let purposeSpeedRead = "四段式速读"

    //MARK: - AI 增强批（端上档／ RCS／ 速读／ 综述自检）

    //端上模型档
    public static let aiProfileOnDeviceName = "设备端（Apple Foundation Models）"
    public static let aiProfileKindLabel = "档案类型"
    public static let aiProfileKindCloud = "云端"
    public static let aiProfileKindOnDevice = "端上"
    public static let aiProfilesOnDeviceBadge = "（端上）"
    public static let aiOnDeviceHealthTitle = "端上模型体检"
    public static let aiOnDevicePrivacyNote = "设备端模型：数据不出本机"
    public static let aiOnDevicePerfNote = "设备端模型响应为数秒级；生成参数仅映射系统框架可表达子集，其余显式忽略"
    public static func aiOnDeviceContextTokens(_ tokens: Int) -> String {
        "上下文窗 \(tokens) tokens"
    }
    public static func aiOnDeviceBlockLine(_ label: String, _ guidance: String) -> String {
        "\(label)：\(guidance)"
    }
    public static func aiDegradeNotice(_ reason: String) -> String {
        "云端不可达（\(reason)）：本次应答已改由设备端模型生成；此前发往云端的请求可能已到达，无法撤回。"
    }

    //RCS 逐块评分
    public static let rcsButton = "逐块评分"
    public static let rcsNeedsSelection = "逐块评分需要至少一条证据：请先在结果上「加入综合证据」"
    public static let rcsCardTitle = "逐块评分结果"
    public static let rcsAllFilteredNote = "全部块低于相关性阈值，未发送综合请求"
    public static func rcsBlockScoreLine(_ index: Int, _ score: Int) -> String {
        "块 \(index) · 评分 \(score)"
    }
    public static let rcsPlanDisclosureTitle = "流程计划"
    public static func rcsParseFailureCount(_ count: Int) -> String {
        "评分响应解析失败 \(count) 块（按 0 分出局）"
    }

    //综述自检（续）
    public static func reviewVerdictSummary(_ total: Int, _ unsupported: Int) -> String {
        "逐断言检查：共 \(total) 条，其中无支撑 \(unsupported) 条"
    }
    public static func reviewRetrievedQueries(_ queries: Int, _ supplemented: Int) -> String {
        "回检索 \(queries) 问，补入证据 \(supplemented) 块"
    }

    //四段式速读
    public static let speedReadButton = "四段速读"
    public static let speedReadNeedsSelection = "四段速读需要至少一条证据：请先在结果上「加入综合证据」"
    public static let speedReadCardTitle = "速读卡"
    public static let speedReadSectionMissing = "模型未给出该段"
    public static func speedReadBudgetDropped(_ count: Int) -> String {
        "已按预算裁剪，截去 \(count) 字符"
    }
    public static let pageUnknownLabel = "页码未知"

    //综述自检
    public static let reviewButton = "综述"
    public static let reviewNeedsSelection = "综述需要至少一条证据：请先在结果上「加入综合证据」"
    public static let reviewCardTitle = "综述自检报告"
    public static let reviewFinalDraftLabel = "最终稿"
    public static let reviewAdopt = "采用"
    public static let reviewDiscard = "弃用"
    public static let reviewAdoptedNote = "已采用（仅写入对话与剪贴板，未写批注库）"
    public static let reviewDiscardedNote = "已弃用"
    public static func reviewRoundLabel(_ round: Int) -> String {
        "第 \(round) 轮"
    }
    public static let reviewCitationNote = "对话引用脚注按你确认的草稿载荷解析；最终稿引用以正文 [n] 标注为准。"
    public static let aiProfilesAdd = "新增"
    public static let aiProfilesDefaultBadge = "（默认）"
    public static let aiProfilesDelete = "删除"
    public static let aiProfilesFieldKey = "API 密钥"
    public static let aiProfilesFieldModel = "模型"
    public static let aiProfilesFieldName = "名称"
    public static let aiProfilesFieldURL = "服务地址（https）"
    public static let aiProfilesFollowDefault = "跟随默认"
    public static let aiProfilesKeyFileMissing = "密钥文件缺失"
    public static let aiProfilesKeyFileOK = "密钥文件在位（权限 600）"
    public static let aiProfilesKeyFilePerms = "密钥文件权限过宽（应 600）"
    public static let aiProfilesKeyFileTitle = "密钥文件"
    public static let aiProfilesKeyMissing = "未配置"
    public static let aiProfilesKeySet = "已配置"
    public static let aiProfilesNewName = "新档案名称"
    public static let aiProfilesRoutingTitle = "按用途路由"
    public static let aiProfilesSaveKey = "保存密钥"
    public static let aiProfilesSectionTitle = "服务档案"
    public static let aiProfilesSetDefault = "设为默认"
    public static let aiProfilesSettingsTitle = "AI 配置"
    public static let aiProfilesTest = "测试连通"
    public static let aiProfilesTestBadURL = "地址无效（需 https）"
    public static let aiProfilesTestFail = "失败"
    public static let aiProfilesTestOK = "连通正常"
    public static let aiProfilesTesting = "测试中…"
    public static let commonDone = "完成"
    public static let aiProfileInvalidURLError = "baseURL 无效（需 https:// 开头）"
    public static let aiProfileKeyMissingError = "API 密钥缺失（Keychain 读取失败）"
    public static let twoPageEnter = "双页对开"
    public static let twoPageExit = "单页连续"
    public static let highlightsStaleSnippet = "原文本已变化"
    public static func highlightsExportFileName(_ title: String) -> String {
        "\(title)-高亮.md"
    }
    public static let aiCitationStaleSuffix = "（出处已失效）"

    // MARK: - 阅读增强（历史回跳/锁定锚点/概览弹窗）

    public static let historyBack = "返回上一位置（⌘[）"
    public static let historyForward = "前进（⌘]）"
    public static let historyLockPosition = "锁定当前位置"
    public static let historyUnlockPosition = "取消锁定"
    public static func anchorBadge(_ page: Int) -> String {
        "锚点 P\(page)"
    }
    public static let overviewToggle = "概览（⌘O）"
    public static let overviewTitle = "页面概览"

    // MARK: - Smart Jump（引文接线；纯字符串）

    public static let citationNotFound = "库内未找到该引文对应文献"

    // MARK: - 批（纯字符串）

    public static let styleGroupChinese = "中文"
    public static let styleGroupEnglish = "英文国际"
    public static let styleGroupOther = "其他"
    public static func otherVersions(_ count: Int) -> String {
        "另有 \(count) 个版本"
    }
    public static let chooseVersionTitle = "选择版本"
    public static let highlightAction = "高亮"
    public static let underlineAction = "下划线"
    public static let changeToUnderline = "改为下划线"
    public static let changeToHighlight = "改为高亮"

    // MARK: - 批注体验批（侧边批注面板/AI 纳入批注）

    /// 工具条批注入口 + 侧栏可访问性标签。
    public static let annotationsToggle = "批注"
    public static let annotationsSidebarEmpty = "本书暂无批注"
    /// 快速批注输入框占位：有选区 = 锚选区，无选区 = 整页批注。
    public static let annotationsQuickPlaceholder = "就此选段批注，回车保存…"
    /// 条目来源/形态标记。
    public static let annotationsPageNoteBadge = "整页批注"
    public static let annotationsSourceOriginal = "原件视图"
    public static let annotationsSourceOCR = "OCR 视图"
    public static func annotationsCount(_ count: Int) -> String {
        "\(count) 条批注"
    }
    /// 侧栏条目备注编辑占位。
    public static let annotationsNotePlaceholder = "备注（回车保存）"
    /// 写入失败提示（store 缺失 / 页码未落地均不静默）。
    public static let annotationsStoreUnavailable = "批注库不可用，无法保存"
    public static let annotationsPageUnavailable = "页码未落地，无法整页批注"
    public static let annotationsSaved = "已保存"
    /// AI 回答存为批注按钮与回执。
    public static let annotationSaveAIAnswer = "存为批注"
    public static let annotationAISaved = "回答已存为批注"
    public static let annotationAIEmpty = "没有可保存的回答内容"

    // MARK: - 批注加密（设置页「批注」区块）

    public static let annotationEncryptionSection = "批注"
    public static let annotationEncryptionToggle = "加密存储批注"
    /// 开关语义说明：开=新批注加密存储＋既有批注自动迁移（幂等）；关=旧密
    /// 文批注显示占位。占位串本体在核心层（AnnotationCrypto），此处不重复。
    public static let annotationEncryptionNote = "开启后，新批注将以加密形式存储在本机，并自动迁移既有批注；密钥保存在本机钥匙串。关闭后，已加密的批注将显示为［已加密批注］，重新开启即可恢复显示。"

    // MARK: - 元数据写入回执（原 AppState 硬编码文案迁移，逐字不变）

    /// 元数据写入成功回执（索引写入，原件永不改动）。
    public static let metaWriteSuccess = "已写入索引（原件未改动）"
    /// 写入目标书目不存在。
    public static let metaWriteMissingBook = "书目不存在"
    /// 元数据写入失败前缀（后接错误描述）。
    public static let metaWriteFailurePrefix = "写入失败: "

    // MARK: - 稳定页码（docs/PAGE-BASIS.md；sidecar 手动导入）

    /// 页码映射 sidecar 选择面板提示。
    public static let pageMapImportPrompt = "选择页码映射 sidecar（CSV）"
    /// 导入完成回执（审计记录：接受/拒收/未匹配逐项计数）。
    public static func pageMapImportDone(_ books: Int, _ accepted: Int,
                                         _ rejected: Int, _ unmatched: Int) -> String {
        "页码映射导入完成：\(books) 本，接受 \(accepted) 行，拒收 \(rejected) 行，未匹配书 \(unmatched) 本（未匹配不猜测）"
    }
    /// 导入失败前缀（后接错误描述）。
    public static let pageMapImportFailurePrefix = "页码映射导入失败: "
    /// booksSection 导入入口按钮。
    public static let pageMapImportButton = "导入页码映射（CSV）"
    /// 语义注记：印刷页码为声明制（sidecar 导入），存储基准恒为物理页。
    public static let pageMapImportNote = "印刷页码仅来自声明（sidecar CSV），存储基准恒为物理页；未声明的页如实显示未知"

    // MARK: - 元数据抓取（手动唯一；总开关默认关）

    public static let metadataSection = "元数据在线补全"
    public static let metadataFetchToggle = "允许在线查询（默认关）"
    public static let metadataFetchToggleNote = "手动查询会发送标识符或标题和作者。缺少标题时，使用整理后的文件名。每源最多一次，不发送完整路径、指纹或批注。"
    public static let metadataSourceCrossref = "Crossref（DOI）"
    public static let metadataSourceArxiv = "arXiv"
    public static let metadataSourceDBLP = "DBLP（标题）"
    public static let metadataSourceSS = "Semantic Scholar（标题）"
    /// 功能扩展：第五源 OpenLibrary（公开免钥；模糊回退链尾）。
    public static let metadataSourceOpenLibrary = "Open Library（标题）"
    public static let metadataFetchButton = "在线补全元数据"
    public static let metadataDOIPlaceholder = "DOI（可选，粘贴）"
    public static let metadataArxivPlaceholder = "arXiv ID（可选，粘贴）"
    public static let metadataFetchDisabledNote = "先在设置的「元数据在线补全」打开总开关"
    public static let metadataFetchMasterOff = "总开关未开，未发送任何请求"
    public static func metadataFetchDone(_ filled: Int, _ sources: Int) -> String {
        "补全完成：新填 \(filled) 个字段，涉及 \(sources) 个来源；既有值一律未覆盖"
    }

    // MARK: - 键位外置（诊断面板；重启生效）

    public static let keybindingsSection = "键盘快捷键"
    public static let keybindingsSourceBuiltin = "内置"
    public static let keybindingsSourceUser = "用户覆盖"
    public static let keybindingsDisabledBadge = "已禁绑"
    public static let keybindingsConflictBadge = "冲突"
    public static let keybindingsOpenFile = "打开 keybindings.json"
    public static let keybindingsRestartNote = "修改 keybindings.json 后重启应用生效；文件只写差异条目，未知动作会被忽略并记录告警"
    public static let keybindingsContextApp = "应用"
    public static let keybindingsContextReader = "阅读器"

    // MARK: - 无障碍走查补缺（VoiceOver 语义标签与状态值）

    /// 版本行主版徽章（勾选圆标）语义。
    public static let versionPrimaryBadge = "主版本"
    /// 引导步骤完成勾语义。
    public static let stepDoneBadge = "已完成"
    /// 收藏条目类型语义（书 / 页 / 检索式）。
    public static let favoriteKindBook = "收藏类型：书"
    public static let favoriteKindPage = "收藏类型：页"
    public static let favoriteKindQuery = "收藏类型：检索式"
    /// 分组展开/收起状态值。
    public static let groupExpandedState = "已展开"
    public static let groupCollapsedState = "已收起"
    /// 版本选中状态值。
    public static let versionSelectedState = "当前显示版本"
    public static let versionUnselectedState = "备选版本"

    // MARK: iOS/iPadOS 版（副本/阅读器/批注涂画/回传）

    public static let iosTabLibrary = "书库"
    public static let iosTabSettings = "设置"
    public static let iosReadOnlyDeviceNotice = "iPhone 为只读端：不提供批注与涂画；iPad 可写。"
    public static let iosBookMissing = "该书目已不在当前副本中（副本可能已更新）。"

    public static let iosReplicaSection = "检索索引副本（Mac 上传 → 本端只读）"
    public static let iosReplicaMissingTitle = "还没有检索副本"
    public static let iosReplicaMissingDetail = "在下方「检索索引副本」填入 WebDAV 配置并点「下载副本」；Mac 端先在设置里上传索引。"
    public static let iosReplicaFailedTitle = "副本打开失败"
    public static let iosWebDAVUsername = "用户名"
    public static let iosWebDAVPassword = "密码（只存本机钥匙串）"
    public static let iosWebDAVNotConfigured = "WebDAV 未配置（需服务地址、用户名与本机钥匙串密码）"
    public static let iosPasswordSaved = "密码已存本机钥匙串"
    public static let iosReplicaDownloadNow = "下载副本"
    public static let iosReplicaDownloading = "下载中…"
    public static let iosReplicaUpToDate = "副本已是最新（同内容指纹，跳过下载）"
    public static func iosReplicaDownloaded(volumes: Int, hash: String) -> String {
        "副本已更新（\(volumes) 卷，校验 \(hash)…）"
    }
    public static func iosReplicaDownloadFailed(_ reason: String) -> String { "副本下载失败：\(reason)" }
    public static let iosReplicaPrivacyNote = "副本含全部书名与检索倒排；校验失败一律拒收且保留旧副本。"

    // Share Extension 入站收录回执。
    public static let iosShareInboxUnavailable = "收录收件箱不可用（App Group 未授权）"
    public static func iosShareInboxMerged(pdf: Int, captures: Int, failed: Int) -> String {
        var parts: [String] = []
        if pdf > 0 { parts.append("收录 PDF \(pdf)") }
        if captures > 0 { parts.append("收录链接 \(captures)") }
        if failed > 0 { parts.append("失败 \(failed)") }
        return parts.joined(separator: " · ")
    }

    public static let iosAnnotationsSection = "批注与涂画（独立库；iPad 可写）"
    public static let iosAnnotationsImport = "导入批注包（JSON）…"
    public static let iosAnnotationsExport = "导出批注包（含删除记录，可完整重建）…"
    public static func iosAnnotationsImported(_ inserted: Int, _ skipped: Int) -> String {
        "合并完成：新增 \(inserted)，幂等跳过 \(skipped)"
    }
    public static func iosAnnotationsExported(_ name: String) -> String { "已导出 \(name)（用分享面板发送）" }
    public static func iosAnnotationFailed(_ reason: String) -> String { "批注操作失败：\(reason)" }

    public static let iosLibraryRootSection = "书库 WebDAV 根路径（按需下载原件用；默认空=禁用）"
    public static let iosLibraryRootPlaceholder = "如 /Library（远端目录）"
    public static let iosLibraryRootNote = "原件下载后逐字节核对指纹；不符即删除并报错，绝不打开存疑副本。"

    public static func iosBookPages(_ n: Int) -> String { "页 \(n)" }
    public static let iosBookOriginalReady = "原件已就绪"
    public static func iosBookHits(_ n: Int) -> String { "命中 \(n) 页" }

    public static let iosSearchEmptyTitle = "输入关键词开始检索"
    public static let iosSearchEmptyDetail = "检索与 Mac 端同一引擎，结果全等（只读）。"
    public static func iosHitPageOnly(_ page: Int) -> String { "（第 \(page) 页命中）" }
    public static func iosHitPageLabel(_ page: Int) -> String { "物理页 \(page)" }

    public static func iosOriginalMissing(_ title: String) -> String {
        "「\(title)」的原件不在本机。通过文件导入或 WebDAV 按需下载获取；原件只读、永不写入。"
    }
    public static let iosOriginalImportFromFiles = "从「文件」导入…"
    public static let iosOriginalDownloadFromWebDAV = "从 WebDAV 下载原件"
    public static let iosOriginalPrivacyNote = "导入件按指纹与书目关联；不匹配则保留文件但不关联（不猜测）。"
    public static let iosOriginalImportUnmatched = "已导入文件，但指纹与任何书目不匹配（保留未关联）"
    public static let iosOriginalImportMatched = "已导入并关联到对应书目"
    public static func iosOriginalImportFailed(_ reason: String) -> String { "导入失败：\(reason)" }
    public static let iosOriginalDownloadOK = "原件已下载并校验通过"
    public static func iosOriginalDownloadFailed(_ reason: String) -> String { "下载失败：\(reason)" }

    public static func iosReaderPage(_ current: Int, _ total: Int) -> String { "第 \(current) / \(total) 页" }
    public static let iosHighlightSaved = "高亮已存（独立批注库）"

    public static let iosShareQueued = "已入待发队列并发送（WebDAV 就绪时）"
    public static let iosShareQueuedOffline = "已入待发队列（WebDAV 未配置，稍后手动发送）"
    public static func iosShareSent(_ n: Int) -> String { "已发送 \(n) 条到 Mac 收件箱" }
    public static let iosShareNothingToSend = "暂无待发件"
    public static func iosShareFailed(_ reason: String) -> String { "回传失败：\(reason)" }
    public static let iosInboxGroupTitle = "手机分享收取（LiteratureSearch/sync/inbox/；同名跳过、远端不删）"
    public static let iosInboxPullNow = "拉取手机分享"
    public static let iosInboxPulling = "拉取中…"
    public static func iosInboxPulled(_ downloaded: Int, _ existing: Int, _ filtered: Int) -> String {
        "下载 \(downloaded) · 已存在跳过 \(existing) · 白名单/上限滤除 \(filtered)"
    }
    public static func iosInboxPullFailed(_ reason: String) -> String { "拉取失败：\(reason)" }

    // 手表伴侣（今日一句 + 阅读进度；applicationContext 合并推送）
    public static let iosWatchPushCompanion = "推送今日一句与进度"
    public static func iosWatchCompanionSent(_ what: String) -> String { "已向手表推送：\(what)（摘要一并携带）" }
    public static let iosWatchCompanionNothing = "暂无可推送内容：今日一句与阅读进度均为空"
    public static func iosWatchCompanionFailed(_ reason: String) -> String { "今日一句与进度未推送：\(reason)" }

    //── 检索增强批（语法层 预览 分区 上下文 相似 调试面板）──

    //查询语法帮助（分派基准与字段集如实写明）
    public static let syntaxHelp = "语法：作者: 书名: 语言: 版本: 标签: 来源: 限定字段；值= 精确，值~正则（大小写不敏感，超时1秒按不命中）；\"短语\" 整体匹配；多个词隐式 AND。无以上符号的查询按普通关键词搜索。全角冒号不触发语法。"

    //命中页预览
    public static let previewOpen = "命中页预览"
    public static let previewLoading = "预览加载中…"
    public static let previewEmpty = "无命中页可预览"
    public static let physicalPageShort = "第 "
    public static func previewTruncated(_ shown: Int, _ total: Int) -> String {
        "预览已截断：显示 \(shown) / 共 \(total) 页命中（每书最多 4 页）"
    }

    //书内/全库两级分区
    public static let scopeSectionBook = "当前书内"
    public static let scopeSectionBookEmpty = "当前书内无命中"
    public static func bookScopeCount(_ hits: Int, _ total: Int) -> String {
        "书内命中 \(hits) 行（复核后 \(total) 页）"
    }

    //上下文扩展
    public static let contextToggle = "上下文"
    public static let contextSectionTitle = "页/节上下文"
    public static let contextNoTOC = "无目录"
    public static let contextPrev = "前页"
    public static let contextNext = "后页"
    public static let contextSectionLabel = "所在节"

    //相似文档
    public static let similarBooksTitle = "相似文档"
    public static let similarBooksLoading = "计算中…"
    public static let similarBooksEmpty = "暂无相似文档（倒排索引未建或文本过短）"
    public static func similarScore(_ v: Double) -> String { String(format: "%.3f", v) }

    //检索调试面板（诊断面；无写动作）
    public static let debugPanelEntry = "检索调试"
    public static let debugPanelTitle = "检索调试面板"
    public static let debugPanelLastQuery = "最近一次查询"
    public static let debugPanelQuery = "查询串"
    public static let debugPanelAST = "语法概要"
    public static let debugPanelTermCandidates = "各词候选数"
    public static let debugPanelIntersection = "交集候选页"
    public static let debugPanelPagesLoaded = "物化页数"
    public static let debugPanelTotal = "复核后命中"
    public static let debugPanelPhases = "分相耗时"
    public static let debugPanelTruncated = "已截断"
    public static let debugPanelYes = "是"
    public static let debugPanelNo = "否"
    public static let debugPanelRegexTimeout = "本次查询发生过正则超时（>1.0s 的正则按不命中处理，如实标注）"
    public static let debugPanelNoQuery = "尚未检索（无诊断数据）"
    public static let debugPanelFieldOnlyNote = "字段限定查询：书级过滤命中不产生页级词命中，页级检索计 0 页（如实基准）。"
    public static let debugPanelCountCaliber = "基准"
    public static let countCaliberCharacter = "字符级（CJK/拼音）"
    public static let countCaliberWord = "拉丁词级（整词）"
    public static let countCaliberWordNote = "整词匹配，词内片段（如 copyrights 中的 rights）不计入。"
    public static let debugPanelRoutedTerms = "词项路由"

    //── 读后出口批（摘录板 总列表+删除撤销 每日回顾 批量导出）──

    //批注区（侧栏 + 三模式壳）
    public static let navExcerpts = "批注"
    public static let excerptModeBoard = "摘录板"
    public static let excerptModeList = "总列表"
    public static let excerptModeReview = "每日回顾"
    public static let annotationExportOpen = "导出…"
    public static let excerptUnknownSource = "未知来源"
    public static let excerptLoadMore = "加载更多"
    public static func annotationLoadedTotal(_ loaded: Int, _ total: Int) -> String {
        "已加载 \(loaded) / 共 \(total) 条"
    }
    public static let annotationsLibraryEmpty = "全库暂无批注"

    //删除撤销 toast
    public static let annotationDeletedToast = "已删除批注"
    public static let annotationUndoButton = "撤销"

    //每日回顾
    public static let reviewPresetYesterday = "昨日"
    public static let reviewPresetLast7 = "近7日"
    public static let reviewPresetLast30 = "近30日"
    public static let reviewPresetCustom = "自定义"
    public static let reviewCustomStart = "开始日期"
    public static let reviewCustomEnd = "结束日期"
    public static let reviewEmptyYesterday = "昨日无批注"
    public static let reviewEmptyRange = "所选区间无批注"

    //批量导出
    public static let annotationExportTitle = "批量导出批注与引注"
    public static let annotationExportAnnotationsMD = "批注 Markdown（每书一文件）"
    public static let annotationExportAnnotationsCSV = "批注 CSV（全库单文件）"
    /// 批注导出补缺两格式（默认关，不破旧调用）。
    public static let annotationExportAnnotationsHTML = "批注 HTML（全库单文件）"
    public static let annotationExportAnnotationsTXT = "批注 TXT（全库单文件）"
    public static let annotationExportCitationsMD = "引注 Markdown"
    public static let annotationExportCitationsCSV = "引注 CSV"
    public static let annotationExportStart = "开始导出"
    public static let annotationExportCancel = "取消导出"
    public static func annotationExportProgressLine(_ done: Int, _ total: Int, _ failed: Int) -> String {
        "已处理 \(done) / 共 \(total) 本书（失败 \(failed)）"
    }
    public static func annotationExportCurrentBook(_ book: String) -> String {
        "正在导出：\(book)"
    }
    public static let annotationExportDirectoryHint = "导出目录（在书库页「更改导出目录」可改）"
    public static let annotationExportResumeHint = "检测到未完成的导出：续跑将跳过已完成书目，从失败/未处理处继续"
    public static let annotationExportResume = "续跑上次目录"
    public static func annotationExportDoneLine(_ files: Int, _ rows: Int) -> String {
        "完成：\(files) 个文件，\(rows) 条批注记录"
    }
    public static func annotationExportCancelledLine(_ files: Int) -> String {
        "已取消：已写 \(files) 个文件保留，同目录续跑可补齐"
    }
    public static let annotationExportFailedBooks = "失败书目："
    public static let annotationExportStoreUnavailable = "批注库不可用，无法导出"
    public static let annotationExportAllFailed = "导出失败：全部书目处理失败，详见失败书目列表"

    //── 阅读器批（单字符 Marks 会话恢复 快照窗 f 键
    //角标 对照工作台）——五件全部新文案一键区，照 惯例 ──

    //marks（armed 提示与回执；未命中如实提示不静默）
    public static let marksArmSet = "标记字母…（小写本书 · 大写全库）"
    public static let marksArmJump = "跳转到…（字母）"
    public static func markSetDone(_ symbol: String) -> String {
        "已设标记 \(symbol)"
    }
    public static let markNotFound = "无此标记"
    public static let markTargetMissing = "标记指向的书不在当前库"
    public static let marksStoreUnavailable = "批注库不可用，标记功能不可用"

    //follow（角标＋轮换降级处理横幅）
    public static let followNoCandidates = "本页无引文候选"
    public static func followBanner(total: Int, current: Int) -> String {
        "候选 \(current)/\(total) ◀▶ 轮换 · 回车选定 · ESC 取消"
    }

    //快照窗（选区操作条第四钮＋托盘）
    public static let snapshotAction = "快照"
    public static func snapshotWindowTitle(_ title: String, _ page: Int) -> String {
        "\(title) · P\(page)"
    }
    public static let snapshotRenderFailed = "快照渲染失败（选区或页面不可用）"
    public static let snapshotTrayTitle = "快照窗"
    public static let snapshotTrayEmpty = "无快照窗"
    public static let snapshotTrayRaise = "前置"

    public static func readingProgressBadge(_ read: Int, _ total: Int, _ percent: Int) -> String {
        "已读 P\(read)/\(total)（\(percent)%）"
    }
    public static let snapshotCloseAll = "全部关闭"
    public static func snapshotTrayCount(_ count: Int) -> String {
        "\(count) 个快照窗"
    }

    //对照工作台（搜索分组版本行入口）
    public static let workbenchButton = "对照"
    public static let workbenchCompareHint = "与组内选中版本开对照工作台"
    public static let workbenchWindowTitle = "对照工作台"
    public static let workbenchLinkedHint = "滚动联动：主视图 → 对照视图（单向）"
    public static let workbenchPrimaryBadge = "主"
    public static let workbenchSecondaryBadge = "对照"
    public static let workbenchSelfCompareDenied = "同一版本不能自对照"
    public static let workbenchUnavailable = "对照工作台不可用（库未开或书缺失）"

    //会话恢复（还原失败一次显式提示，不阻塞启动）
    public static let sessionRestoreUnavailable = "上次会话还原失败（书目缺失或库不可用），已跳过"

    // ── 新增文案 ──

    // 书库根死配置降级处理删除后的 fail-closed 文案
    public static let iosWebDAVLibraryRootMissing = "书库 WebDAV 根路径未配置：请先在设置里填写库根远端目录"

    // 烧录导出（书详情导出菜单；导出=副本，原件永不写）
    public static let burnExportEntry = "导出含批注的 PDF 副本…"
    public static func burnExportFailed(_ reason: String) -> String { "导出失败：\(reason)" }
    public static func burnExportDoneWithCount(_ name: String, applied: Int, skipped: Int) -> String {
        "已导出副本：\(name)（原件未改动；高亮/下划线 \(applied)，跳过 \(skipped)）"
    }
    public static let burnExportOriginalMissing = "本机无该书原件，无法导出"
    public static let burnExportNote = "导出 = 副本出口（-annotated 后缀，绝不覆盖既有文件）；原书原件与自有批注库都不改动。"

    // 前置页检索屏蔽（默认关；查询后过滤）
    public static let frontMatterToggle = "跳过目录/版权等前置页"
    public static func frontMatterBlockedCount(_ n: Int) -> String { "已屏蔽前置页命中 \(n) 页" }
    public static func frontMatterZeroHitHint(_ n: Int) -> String { "有 \(n) 页命中位于前置页，关闭「跳过前置页」可见" }
    public static let bodyStartFieldLabel = "正文起始物理页"
    public static let bodyStartFieldPlaceholder = "如 15（留空 = 未设置）"
    public static let bodyStartFieldHint = "目录/版权/摘要等前置页的检索命中可被「跳过前置页」屏蔽；正文第一页填这里。"
    public static let bodyStartSaved = "正文起始页已保存"
    public static let bodyStartCleared = "正文起始页已清除"
    public static let bodyStartInvalid = "页码须为 ≥1 的整数"

    // MARK: - 内容类别：术语＋工具书开关＋扫描工具书目录

    /// 设置页「内容类别」区块。
    public static let contentCategorySection = "内容类别"
    public static let includeToolBooksToggle = "检索含工具书"
    /// 说明行（用户基准：工具书=引注手册/辞典/百科等参考书，默认不入检索结果）。
    public static let includeToolBooksNote = "工具书（引注手册、辞典、百科等参考书）默认不入检索结果；打开后参与检索，无需重新索引。"
    /// 对书域根全量重扫（skip-unchanged 语义自动补回清退的工具书；
    /// 补回的行 content_category 判为工具书→开关关闭时仍不入结果）。
    public static let scanToolbookButton = "扫描工具书目录"
    public static let scanToolbookNote = "对书域根做一次全量索引扫描（未变更的文件自动跳过），把本次清退的工具书补回索引库；补回后仍受上方开关控制。"
    public static let scanToolbookRunning = "扫描中…"
    public static let scanToolbookNoRoot = "未授权书域根目录：请先在书库页选择文献目录"
    public static let scanToolbookFailed = "扫描失败"
    public static func scanToolbookDone(added: Int, updated: Int, skipped: Int) -> String {
        "扫描完成：新增 \(added)，更新 \(updated)，跳过未变更 \(skipped)"
    }


    public static let librarySnapshotSection = "库快照（本机索引库）"
    public static let librarySnapshotBackup = "立即备份"
    public static let librarySnapshotRestore = "恢复"
    /// 说明行（基准：SQLite backup API 热备活库安全；恢复有安全网；重启生效）。
    public static let librarySnapshotNote = "对索引库做热备份（SQLite backup API，活库安全，不落半成品）；快照存于 Application Support/LiteratureSearch/snapshots/，默认保留最近 1 份。恢复前自动把当前库再备一份（pre-restore 安全网）；恢复落盘后需重启 App 生效。"
    public static let librarySnapshotWorking = "正在备份索引库…"
    public static let librarySnapshotRestoreWorking = "正在恢复索引库…"
    public static let librarySnapshotEmpty = "暂无快照"
    public static let librarySnapshotFailedPrefix = "操作失败："
    public static func librarySnapshotBackupOK(_ name: String) -> String {
        "已备份快照 \(name)"
    }
    public static func librarySnapshotRestoreOK(_ name: String) -> String {
        "已从 \(name) 恢复（重启 App 后生效）"
    }

    // MARK: - 索引刷新控制台文案
    // 本节只新增键，不改动既有键。

    public static let indexRefreshSection = "索引刷新（重建批次重索引）"
    /// 说明行：按终账逐书重对账；开跑前自动备份，备份失败不开跑。
    public static let indexRefreshNote = "读重建批次终账（jsonl），逐书重对账重索引。开跑前自动备份索引库（SQLite 热备份，只保留最近 1 份）；备份失败不开跑。此后每本书一个事务，暂停/停止只落在书边界。"
    public static let indexRefreshLifecycleNote = "批次在本 App 进程内运行：关闭设置窗不影响运行；App 退出批次即停，已完成部分有流水账可查，重开后可一键续跑。"
    /// 空态引导（无终账时的安全文案——不因空清单误扫索引库）。
    /// 空索引状态的标题文案。
    public static let indexRefreshNoLedgerTitle = "尚未载入终账。"
    public static let indexRefreshNoLedger = "重建批次终账生成后，用「选择终账…」载入生成批次计划；在此之前本面板只做只读展示。"
    public static let indexRefreshChooseLedger = "选择终账…"
    public static let indexRefreshReloadLedger = "重载清单"
    public static let indexRefreshRefreshDisplay = "刷新显示"
    public static func indexRefreshPlanLoaded(_ books: Int, _ pages: Int, _ unresolved: Int) -> String {
        "已生成批次计划：\(books) 本 · 约 \(pages) 页" + (unresolved > 0 ? " · \(indexRefreshUnresolvedNote(unresolved))" : "")
    }
    /// 未配对行文案（unresolved>0 时拼接进计划摘要行）。
    static func indexRefreshUnresolvedNote(_ n: Int) -> String { "另有 \(n) 条终账行在库内无对应书目（不进刷新清单）" }
    public static let indexRefreshPlanEmpty = "终账已载入，但没有可刷新的书（无 sha_after 行或全部未配对）。请换用较新的终账后重载。"
    public static let indexRefreshStart = "开启批次…"
    public static let indexRefreshPause = "暂停"
    public static let indexRefreshPausedStatus = "已暂停（停在书边界）：点「继续」从下一本接着跑"
    public static let indexRefreshResume = "继续"
    public static let indexRefreshStop = "停止批次"
    public static let indexRefreshStarting = "正在开跑前备份…（备份失败不开跑）"
    public static let indexRefreshFailedPrefix = "操作失败："
    public static let indexRefreshLedgerFailedPrefix = "载入终账失败："
    public static let indexRefreshConfirmTitle = "确认批次计划"
    public static let indexRefreshConfirmNote = "开跑前将先自动备份索引库（唯一快照，建新删旧只留最近 1 份）；此后每本书一个事务。点「开跑」才动库。"
    public static let indexRefreshConfirmRun = "开跑"
    public static let indexRefreshCancel = "取消"
    public static func indexRefreshBatchProgress(_ done: Int, _ total: Int) -> String {
        "批次：\(done) / \(total) 本"
    }
    public static func indexRefreshCurrentBook(_ name: String, _ index: Int, _ total: Int) -> String {
        "当前书（\(index)/\(total)）：\(name)"
    }
    /// 索引刷新记录列表标题。
    public static let indexRefreshJournalTitle = "批次流水账（只读）"
    public static func indexRefreshJournalInterrupted(_ pending: Int) -> String {
        "检测到未完成批次（上次未收尾，约 \(pending) 本待跑）。可点「继续上次批次」一键续跑。"
    }
    public static func indexRefreshJournalSettled(_ file: String, _ lastEvent: String) -> String {
        "上次批次 \(file) 已收尾（末事件 \(lastEvent)）。"
    }
    public static let indexRefreshJournalNone = "暂无批次流水账（从未开过批次）。"
    public static func indexRefreshFailedCount(_ n: Int) -> String {
        n > 0 ? "错误 \(n) 本" : ""
    }

    // MARK: - 索引刷新控制台（续跑与对账文案；只增键）

    /// 跨启动续跑（崩溃三态恢复）。
    public static let indexRefreshResumeLastButton = "继续上次批次"
    public static let indexRefreshResumingLast = "正在按流水账重建批次（无快照会先补备）…"
    public static let indexRefreshResumedLast = "已从上次批次的断点继续。"
    public static let indexRefreshResumeLastUnavailable = "没有可续的未完成批次（或终账与流水账均不可读）。"

    /// 窗口期横幅（全局顶栏＋红条旁就地说明；自动显隐）。
    public static let indexRefreshWindowBannerTitle = "重建批次加工中：此期间打开书看到的「指纹失配」提示是预期状态，刷新完成后自动消失。"
    public static let indexRefreshWindowBannerOpen = "查看"
    public static let indexRefreshStaleWindowNote = "索引刷新窗口期：指纹失配提示属预期状态，重建批次刷新完成后自动消失。"
    public static func indexRefreshWindowPeriodProgress(_ done: Int, _ total: Int) -> String {
        "第 \(done)/\(total) 本"
    }
    public static func indexRefreshWindowPeriodPending(_ pending: Int) -> String {
        pending > 0 ? "约 \(pending) 本待跑" : ""
    }

    /// 同步对账（只读半步＋整批一次确认修复半步）。
    public static let indexRefreshSyncAuditButton = "同步对账…"
    public static let indexRefreshAuditRunning = "正在只读对账（逐书核对盘上指纹与库内记录，不写库）…"
    public static func indexRefreshAuditProgress(_ done: Int) -> String {
        "对账中：已核 \(done) 本（只读，不写库）"
    }
    public static func indexRefreshAuditClean(_ audited: Int) -> String {
        "对账完成：\(audited) 本全部一致，无需修复。"
    }
    public static func indexRefreshAuditFound(_ diffs: Int, _ audited: Int) -> String {
        "对账完成：\(audited) 本中 \(diffs) 本有差异（清单见下；修复前红条属预期状态）。"
    }
    public static let indexRefreshAuditFailedPrefix = "对账失败："
    public static let indexRefreshAuditIssueMismatch = "盘上文件指纹与库内记录不一致（窗口期红条书，可修复）"
    public static let indexRefreshAuditIssueMissing = "盘上文件缺失（重索引无法修复，请先补回文件）"
    public static let indexRefreshAuditIssueReadError = "文件不可读或哈希失败"
    public static let indexRefreshAuditSha8None = "—"
    public static func indexRefreshAuditShaPair(_ db: String, _ disk: String) -> String {
        "〔库 \(db) · 盘 \(disk)〕"
    }
    public static let indexRefreshAuditRepairedMark = "〔已修复〕"
    /// 修复确认表（整批一次确认）。
    public static let indexRefreshRepairConfirmTitle = "确认修复差异"
    public static func indexRefreshRepairConfirmNote(_ n: Int) -> String {
        "将对 \(n) 本指纹失配书逐本重新索引（重新配对指纹，消红条）。开跑前自动备份索引库（只留最近 1 份）；此后每本一个事务。文件缺失书不在修复范围。"
    }
    public static func indexRefreshRepairRunButton(_ n: Int) -> String {
        "修复 \(n) 本"
    }
    public static func indexRefreshRepairStarting(_ n: Int) -> String {
        "修复批次开跑（\(n) 本，开跑前自动备份；备份失败不开跑）…"
    }
    public static func indexRefreshRepairDone(_ ok: Int, _ failed: Int) -> String {
        failed == 0 ? "修复完成：\(ok) 本已重新配对。" : "修复收尾：\(ok) 本已重新配对，\(failed) 本失败（见错误清单）。"
    }

    /// 页级进度、ETA 与错误清单文案。
    public static func indexRefreshPageProgress(_ done: Int?, _ total: Int?) -> String {
        switch (done, total) {
        case (let d?, let t?): return "该书已索引 \(d)/\(t) 页"
        case (let d?, nil): return "该书已索引 \(d) 页"
        default: return ""
        }
    }
    public static func indexRefreshEtaLine(_ rate: String, _ eta: String, _ elapsed: String, _ lines: Int) -> String {
        "\(rate) · 预计剩余 \(eta) · 已运行 \(elapsed) · 流水账已落 \(lines) 行"
    }
    public static let indexRefreshCopyButton = "复制清单"
    public static let indexRefreshExportButton = "导出…"
    /// 导出件默认文件名（错误清单/差异清单/三向总表）与速率单位。
    public static let indexRefreshExportErrorsFileName = "索引刷新错误清单"
    public static let indexRefreshExportAuditFileName = "同步对账差异清单"
    public static let indexRefreshExportFinalFileName = "收尾三向对账总表"
    public static func indexRefreshRateText(_ rate: Double) -> String {
        String(format: "%.1f 页/秒", rate)
    }
    public static let indexRefreshCopied = "已复制到剪贴板。"
    public static func indexRefreshExportDone(_ path: String) -> String {
        "已导出：\(path)"
    }
    public static func indexRefreshExportErrorsHeader(_ batchID: String) -> String {
        "索引刷新错误清单（批次 \(batchID.isEmpty ? "—" : batchID)）"
    }
    public static let indexRefreshExportEmpty = "（无错误）"
    public static func indexRefreshExportAuditHeader(_ audited: Int) -> String {
        "同步对账差异清单（共核 \(audited) 本）"
    }
    public static func indexRefreshExportFinalHeader(_ ok: Int, _ failed: Int, _ mismatch: Int) -> String {
        "收尾三向对账总表：\(ok) 本全绿 · \(failed) 本有差异 · 指纹失配 \(mismatch) 本"
    }
    public static let indexRefreshFinalPassLine = "三向对账 PASS：清单＝库内＝盘上。"
    public static let indexRefreshProbeLabel = "批间抽验"

    /// 收尾三向对账文案。
    public static let indexRefreshFinalCheckTitle = "收尾三向对账（清单 / 库内 / 盘上）"
    public static func indexRefreshFinalCheckSummary(_ ok: Int, _ failed: Int, _ mismatch: Int) -> String {
        "三向对账：\(ok) 本全绿 · \(failed) 本有差异 · 指纹失配 \(mismatch) 本。"
    }
    public static let indexRefreshFinalResidueStatus = "批次已完成但收尾对账有残留（差异如实列出，窗口期提示不消）。"
    public static let indexRefreshFinalPassStatus = "收尾对账 PASS：窗口期提示已消失。"
    public static let indexRefreshFinalViewTableButton = "查看差异总表"
    /// 三向对账总表列头（清单/库内/盘上 sha8＋页数三方）。
    public static let indexRefreshFinalColBook = "书目"
    public static let indexRefreshFinalColLedger = "清单"
    public static let indexRefreshFinalColDB = "库内"
    public static let indexRefreshFinalColDisk = "盘上"
    public static let indexRefreshFinalColPages = "页数 清单/库/盘"

    /// 刷新批收尾顺带建页统计覆盖索引（idx_pages_stats）。
    public static let indexRefreshStatsIndexTitle = "页统计索引（零命中诊断加速）"
    public static let indexRefreshStatsIndexBuilt = "已建：本次收尾建好，之后零命中诊断走覆盖索引。"
    public static let indexRefreshStatsIndexAlready = "已存在：无需重建（判别为 O(1)）。"
    public static let indexRefreshStatsIndexSkipped = "已跳过：库内无页表或当前为只读副本，无处建。"
    public static func indexRefreshStatsIndexFailed(_ error: String) -> String {
        "未建成：\(error)。这不影响本次结论——该索引只买时间，不是正确性前提；下次刷新批收尾会再试一次。"
    }
    public static func indexRefreshStatsIndexSeconds(_ seconds: Double) -> String {
        String(format: "耗时 %.1f 秒", seconds)
    }

    // C 线「从检索生成证据」（hybridEvidenceButton/Help，段级向量重排）随 退役
    // App 轻量向量层从 AI 面板移除；三个 hybridNeeds*/NoEvidence 文案随之不再被引用，
    // 键保留不删（历史版本与快照回放可能仍读到），也不新增。

    // MARK: - 检索体验（本节只增键，既有
    // 任何键零改动——l10n-drift-check 验证基准）

    // 输入候选/历史补全条
    public static let completionHint = "选中后回填为检索词"
    public static let completionNavHint = "↑↓ 选择 · Enter 检索 · Esc 收起（* 为前缀建议，按字面检索）"
    public static func completionA11yPrefix(_ query: String) -> String {
        "前缀建议 \(query)，选中后回填为检索词"
    }
    public static func completionA11yHistory(_ query: String, _ hitCount: Int) -> String {
        "历史检索 \(query)，命中 \(hitCount) 页，选中后回填"
    }

    // 「上次选择」锚点行
    public static let anchorRowTitle = "上次选择"
    public static let anchorRowJump = "跳转"
    public static let anchorRowHelp = "回到本查询上一次选中的页面（不计入结果数与排序）"
    public static let anchorRowHint = "跳转到上次选中的页面"
    public static func anchorRowA11y(_ book: String, _ page: Int) -> String {
        "上次选择：\(book) 第 \(page) 页，双击跳转"
    }

    // 设置节「检索与渲染（调试）」
    public static let searchRenderSection = "检索与渲染（调试）"
    public static let renderCacheCountLimit = "概览缩略缓存条数上限"
    public static let renderCacheCostLimit = "概览缩略缓存字节上限"
    public static let renderPrefetchRadius = "概览预取半径（页）"
    public static let renderPixelTier = "概览缩略图像素档"
    public static let renderDefaultUnlimited = "不限（默认）"
    public static let renderPrefetchOff = "关（默认）"
    public static let renderPrefetch1 = "±1 页"
    public static let renderPrefetch2 = "±2 页"
    public static let renderPrefetch3 = "±3 页"
    public static let renderPixelStandard = "标准 320×420（默认）"
    public static let renderPixelHigh = "高清 480×630"
    public static let renderParamsNote = "各项默认＝现行为；缓存上限改大会增加内存占用（档位制硬封顶，无自由输入）。设置即生效，下次打开概览弹窗起作用。"
    public static let habitLearningToggle = "检索习惯学习（上次选择锚点＋输入候选）"
    public static let habitLearningNote = "默认开。学习数据只影响「上次选择」锚点行与输入候选排序，从不改动检索结果列表的排序与计数；数据存本机 Application Support，可随时关闭（关闭即不记录不显示）。"

    // 调试面板只读节（渲染参数当前生效值＋缩略内存估算）
    public static let debugRenderSection = "渲染参数（当前生效值）"
    public static let debugRenderCacheCount = "缩略缓存条数上限"
    public static let debugRenderCacheBytes = "缩略缓存字节上限"
    public static let debugRenderPrefetch = "预取半径"
    public static let debugRenderPixel = "缩略像素档"
    public static let debugRenderThumbBytes = "单页缩略内存（估算）"
    public static let debugRenderCapEstimate = "缓存内存上限（估算）"
    public static let debugHabitLearning = "检索习惯学习"
    public static let debugRenderEngine = "检索引擎（注册表解析）"
    public static let debugRenderUnlimitedDefault = "不限（默认＝现行为）"
    public static let debugRenderOffDefault = "关（默认＝现行为）"
    public static func debugRenderPages(_ n: Int) -> String { "±\(n) 页" }
    public static let debugRenderPixelStandard = "标准 320×420（默认）"
    public static let debugRenderPixelHigh = "高清 480×630"
    public static func debugRenderBytesKB(_ kb: Int) -> String { "≈ \(kb) KB/页（RGBA 估算）" }
    public static func debugRenderBytesMB(_ mb: Int) -> String { "≈ \(mb) MB（按上限档估算）" }
    public static let debugRenderCapNone = "不限（未设上限，无估算基准）"
}
