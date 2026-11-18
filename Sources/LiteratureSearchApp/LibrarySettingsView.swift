import SwiftUI
import LiteratureCore
import LiteratureSearchUI

/// Library & import page: library bar, OCR pair import, AI configuration and
struct LibrarySettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    @AppStorage("readingSerif") private var readingSerif = true
    // 方案一：自动上传/清理开关（UserDefaults 持久化，默认关）。
    @AppStorage(WebDAVUploadOptions.autoUploadDefaultsKey) private var webdavAutoUpload = false
    @AppStorage(WebDAVUploadOptions.cleanupDefaultsKey) private var webdavCleanup = false

    private enum SettingsGroup: String, CaseIterable, Identifiable {
        case appearance, library, citationOCR, aiSync, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .appearance: return L10n.settingsGroupAppearance
            case .library: return L10n.settingsGroupLibrary
            case .citationOCR: return L10n.settingsGroupCitationOCR
            case .aiSync: return L10n.settingsGroupAISync
            case .about: return L10n.settingsGroupAbout
            }
        }
    }

    @State private var group = SettingsGroup.appearance

    // 自动归类（规则列表/增删/开关/上下移/立即归类）。
    @State private var classificationRules: [ClassificationRule] = []
    @State private var newRuleName = ""
    @State private var newRuleMatch = ""
    @State private var newRuleAlgorithm: ClassificationAlgorithm = .any
    @State private var newRuleCategory = ""

    // 渲染参数＋习惯学习开关（默认全＝现行为；硬封顶＝档位制，
    // 无自由数值输入。UserDefaults 键与读取基准唯一原书在
    // ThumbnailRenderParams / SearchMemoryStore——此处只写键）。
    @AppStorage(ThumbnailRenderParams.cacheCountLimitKey) private var thumbCacheCountLimit = 0
    @AppStorage(ThumbnailRenderParams.cacheCostLimitMBKey) private var thumbCacheCostLimitMB = 0
    @AppStorage(ThumbnailRenderParams.prefetchRadiusKey) private var thumbPrefetchRadius = 0
    @AppStorage(ThumbnailRenderParams.pixelTierKey) private var thumbPixelTier = 0
    @AppStorage(SearchMemoryStore.habitLearningDefaultsKey) private var habitLearningEnabled = true

    private var theme: DS.Theme { .storage(dsTheme) }

    var body: some View {
        Form {
            Picker(L10n.settingsGroupLabel, selection: $group) {
                ForEach(SettingsGroup.allCases) { g in
                    Text(g.title).tag(g)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch group {
            case .appearance:
                appearanceSection
                keybindingsSection
            case .library:
                librarySection
                storageSection
                librarySnapshotSection
                indexRefreshSection
                booksSection
                classificationSection
                contentCategorySection
                annotationEncryptionSection
                searchRenderSection
            case .citationOCR:
                citationSection
                metadataSection
                ocrSection
            case .aiSync:
                aiSection
                webdavSection
                syncSection
                localAPISection
            case .about:
                aboutSection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(DS.Color.desk(theme, scheme))
    }

    private var appearanceSection: some View {
        Section(L10n.appearanceSection) {
            Picker(L10n.appearanceSection, selection: $dsTheme) {
                Text(L10n.themeSystem).tag(DS.Theme.system.rawValue)
                Text(L10n.themeGraphite).tag(DS.Theme.graphite.rawValue)
                Text(L10n.themeObsidian).tag(DS.Theme.obsidian.rawValue)
            }
            .pickerStyle(.segmented)
            Toggle(L10n.readingSerifLabel, isOn: $readingSerif)
                .controlSize(.small)
            Text(L10n.readingSerifNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
        }
    }

    //MARK: 键位诊断（只读；兼作键盘审计工具底座）

    /// 冲突 (context, key, modifiers) 集合——红标显示，不问题启动。
    private var keybindingConflictKeys: Set<String> {
        Set(state.keybindings.conflicts().flatMap { conflict in
            conflict.actions.map { "\(conflict.context)|\($0)" }
        })
    }

    private var keybindingsSection: some View {
        Section {
            ForEach(state.keybindings.specs, id: \.self) { spec in
                HStack(spacing: DS.Spacing.sm) {
                    Text(keybindingContextLabel(spec.context))
                        .font(.caption2)
                        .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                        .frame(width: 44, alignment: .leading)
                    Text(spec.action)
                        .font(.caption)
                        .frame(minWidth: 120, alignment: .leading)
                    Text(KeybindingBridge.displayString(spec))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(spec.enabled
                                         ? DS.Color.ink(theme, scheme)
                                         : DS.Color.inkTertiary(theme, scheme))
                    Text(sourceLabel(spec.source))
                        .font(.caption2)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    if !spec.enabled {
                        Text(L10n.keybindingsDisabledBadge)
                            .font(.caption2)
                            .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                    }
                    if keybindingConflictKeys.contains("\(spec.context)|\(spec.action)") {
                        Text(L10n.keybindingsConflictBadge)
                            .font(.caption2)
                            .foregroundStyle(DS.Color.error(theme, scheme))
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(spec.action), \(KeybindingBridge.displayString(spec)), \(sourceLabel(spec.source))")
            }
            ForEach(state.keybindings.warnings, id: \.self) { warning in
                StatusRow(systemImage: "exclamationmark.triangle.fill",
                          text: warning, color: DS.Color.warning(theme, scheme))
            }
            HStack(spacing: DS.Spacing.sm) {
                Button(L10n.keybindingsOpenFile) {
                    openKeybindingsFile()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(L10n.keybindingsOpenFile)
            }
            Text(L10n.keybindingsRestartNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.keybindingsSection)
                    .font(DS.Font.displaySection)
            }
        }
    }

    private func keybindingContextLabel(_ context: String) -> String {
        context == "reader" ? L10n.keybindingsContextReader : L10n.keybindingsContextApp
    }

    private func sourceLabel(_ source: KeybindingSpec.Source) -> String {
        source == .user ? L10n.keybindingsSourceUser : L10n.keybindingsSourceBuiltin
    }

    /// 打开（或定位）用户覆盖文件；文件不存在时 reveal 所在目录便于创建。
    private func openKeybindingsFile() {
        let url = KeybindingRegistry.defaultUserURL()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    private var librarySection: some View {
        Section {
            libraryBar
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.librarySection)
                    .font(DS.Font.displaySection)
            }
        }
    }

    private var booksSection: some View {
        Section {
            booksPanel
            // 印刷页码 sidecar 手动导入入口（声明制；存储基准恒为
            // 物理页，未声明页如实显示未知——原书 docs/PAGE-BASIS.md）。
            HStack(spacing: DS.Spacing.sm) {
                Button(L10n.pageMapImportButton) {
                    state.importPageMapSidecar()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(L10n.pageMapImportButton)
            }
            Text(L10n.pageMapImportNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            if let message = state.pageMapImportMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .accessibilityLabel(message)
            }
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.booksSection)
                    .font(DS.Font.displaySection)
            }
        }
    }

    // MARK: 自动归类（规则即数据；两处显式时机——入库批末/本按钮）

    private var classificationSection: some View {
        Section {
            Text(L10n.classificationHint)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            if classificationRules.isEmpty {
                Text(L10n.classificationEmpty)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            ForEach(classificationRules) { rule in
                classificationRow(rule)
            }
            classificationAddRow
            HStack(spacing: DS.Spacing.sm) {
                Button(L10n.classificationRunNow) {
                    state.runClassificationNow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.classificationStore == nil)
                if !state.classificationMessage.isEmpty {
                    Text(state.classificationMessage)
                        .font(.caption)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
            }
            if let counts = classificationCounts {
                Text(counts)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            }
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.classificationSection)
                    .font(DS.Font.displaySection)
            }
        }
        .onAppear { reloadClassification() }
    }

    // MARK: 批注加密（开关＋说明；默认关）

    /// 键名单一事实源：AnnotationCrypto.userDefaultsKey（与 store 写/读/
    /// 迁移钩共用同一 UserDefaults 键，翻转下一笔写入即生效）。
    @AppStorage(AnnotationCrypto.userDefaultsKey) private var annotationEncryptionEnabled = false

    private var annotationEncryptionSection: some View {
        Section {
            Toggle(L10n.annotationEncryptionToggle, isOn: $annotationEncryptionEnabled)
            Text(L10n.annotationEncryptionNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.annotationEncryptionSection)
                    .font(DS.Font.displaySection)
            }
        }
    }

    // MARK: /内容类别（工具书开关＋扫描工具书目录）

    @AppStorage("includeToolBooks") private var includeToolBooks = false

    private var contentCategorySection: some View {
        Section {
            Toggle(L10n.includeToolBooksToggle, isOn: $includeToolBooks)
                .onChange(of: includeToolBooks) { _ in
                    // 切档即生效：query 非空时自动重搜当前检索（filterDomain 同款语义）。
                    if !state.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        state.search()
                    }
                }
            Text(L10n.includeToolBooksNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            // 对书域根全量重扫（skip-unchanged 自动补回清退的工具书）。
            HStack(spacing: DS.Spacing.sm) {
                Button(L10n.scanToolbookButton) {
                    state.scanToolbookDirectory()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.isScanningToolbooks)
                .accessibilityLabel(L10n.scanToolbookButton)
            }
            Text(L10n.scanToolbookNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            if !state.toolbookScanMessage.isEmpty {
                Text(state.toolbookScanMessage)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .accessibilityLabel(state.toolbookScanMessage)
            }
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.contentCategorySection)
                    .font(DS.Font.displaySection)
            }
        }
    }

    // MARK: 检索与渲染（调试）：渲染参数＋习惯学习开关

    private var searchRenderSection: some View {
        Section {
            Picker(L10n.renderCacheCountLimit, selection: $thumbCacheCountLimit) {
                Text(L10n.renderDefaultUnlimited).tag(0)
                Text("60").tag(60)
                Text("120").tag(120)
                Text("240").tag(240)
            }
            Picker(L10n.renderCacheCostLimit, selection: $thumbCacheCostLimitMB) {
                Text(L10n.renderDefaultUnlimited).tag(0)
                Text("64 MB").tag(64)
                Text("128 MB").tag(128)
                Text("256 MB").tag(256)
            }
            Picker(L10n.renderPrefetchRadius, selection: $thumbPrefetchRadius) {
                Text(L10n.renderPrefetchOff).tag(0)
                Text(L10n.renderPrefetch1).tag(1)
                Text(L10n.renderPrefetch2).tag(2)
                Text(L10n.renderPrefetch3).tag(3)
            }
            Picker(L10n.renderPixelTier, selection: $thumbPixelTier) {
                Text(L10n.renderPixelStandard).tag(0)
                Text(L10n.renderPixelHigh).tag(1)
            }
            Toggle(L10n.habitLearningToggle, isOn: $habitLearningEnabled)
            Text(L10n.renderParamsNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            Text(L10n.habitLearningNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.searchRenderSection)
                    .font(DS.Font.displaySection)
            }
        }
    }

    /// 规则行：名称/算法档/目标分类＋开关/上下移/删除（最小面）。
    /// 写失败显式报进状态行（应修：try? 静默吞错改 do-catch 上屏）。
    private func classificationRow(_ rule: ClassificationRule) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { on in
                    classificationWrite { try state.classificationStore?.setEnabled(id: rule.id, enabled: on) }
                }))
                .labelsHidden()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.callout)
                    .foregroundStyle(DS.Color.ink(theme, scheme))
                Text("\(rule.algorithm.displayName) · \(rule.matchText) → \(rule.targetCategory)")
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(L10n.classificationMoveUp) {
                classificationWrite { try state.classificationStore?.moveRule(id: rule.id, offset: -1) }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            Button(L10n.classificationMoveDown) {
                classificationWrite { try state.classificationStore?.moveRule(id: rule.id, offset: 1) }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            Button(L10n.actionDelete) {
                classificationWrite { try state.classificationStore?.deleteRule(ids: [rule.id]) }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rule.name)
    }

    /// 设置页归类写操作统一通道：失败写状态行不静默（应修）。
    private func classificationWrite(_ body: () throws -> Void) {
        do {
            try body()
            state.classificationMessage = ""
        } catch {
            state.classificationMessage = L10n.classificationFailed
        }
        reloadClassification()
    }

    private var classificationAddRow: some View {
        HStack(spacing: DS.Spacing.xs) {
            TextField(L10n.classificationNamePlaceholder, text: $newRuleName)
                .textFieldStyle(.dsTextField)
                .frame(maxWidth: 140)
            Picker("", selection: $newRuleAlgorithm) {
                ForEach(ClassificationAlgorithm.allCases, id: \.self) { algo in
                    Text(algo.displayName).tag(algo)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 120)
            TextField(L10n.classificationMatchPlaceholder, text: $newRuleMatch)
                .textFieldStyle(.dsTextField)
                .frame(maxWidth: 240)
            TextField(L10n.classificationCategoryPlaceholder, text: $newRuleCategory)
                .textFieldStyle(.dsTextField)
                .frame(maxWidth: 120)
            Button(L10n.classificationAddRule) { addClassificationRule() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newRuleName.trimmingCharacters(in: .whitespaces).isEmpty
                          || newRuleMatch.trimmingCharacters(in: .whitespaces).isEmpty
                          || newRuleCategory.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var classificationCounts: String? {
        guard let store = state.classificationStore else { return nil }
        do {
            let classified = try store.classifications().count
            let unclassified = try store.unclassifiedCount()
            return L10n.classificationStatus(classificationRules.count, classified, unclassified)
        } catch {
            return nil
        }
    }

    private func reloadClassification() {
        do {
            classificationRules = try state.classificationStore?.rules() ?? []
        } catch {
            classificationRules = []
            state.classificationMessage = L10n.classificationFailed
        }
    }

    private func addClassificationRule() {
        guard let store = state.classificationStore else { return }
        do {
            _ = try store.addRule(name: newRuleName.trimmingCharacters(in: .whitespaces),
                                  matchText: newRuleMatch.trimmingCharacters(in: .whitespaces),
                                  algorithm: newRuleAlgorithm,
                                  targetCategory: newRuleCategory.trimmingCharacters(in: .whitespaces))
            state.classificationMessage = ""
        } catch {
            state.classificationMessage = L10n.classificationFailed
        }
        newRuleName = ""; newRuleMatch = ""; newRuleCategory = ""
        reloadClassification()
    }

    // MARK: 存储位置（索引库只读展示 + 导出目录可更改）
    //
    // 索引库位置本期只读展示，不做迁移——迁移涉及库重建与指纹重算，留
    // + 单独评估；导出目录 NSOpenPanel 更改，UserDefaults
    // 持久化，导出动作（快照导出）以该目录为初始落点。

    private var storageSection: some View {
        Section {
            storagePanel
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.storageSection)
                    .font(DS.Font.displaySection)
            }
        }
    }

    private var storagePanel: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            LabeledContent {
                Text(state.dbURL.path)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } label: {
                Text(L10n.storageIndexDBLabel).font(.callout)
            }
            Text(L10n.storageIndexDBNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            LabeledContent {
                Text(state.exportDirectoryPath)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } label: {
                Text(L10n.storageExportDirLabel).font(.callout)
            }
            HStack(spacing: DS.Spacing.sm) {
                Button(L10n.storageChooseExportDir) { state.chooseExportDirectory() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(L10n.storageChooseExportDir)
            }
            if let warning = state.storageWarning {
                StatusRow(systemImage: "exclamationmark.triangle.fill",
                          text: warning, color: DS.Color.error(theme, scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    /// 面板 Store 惰性创建（持 AppState.dbURL 活库真实路径；创建不失败，
    /// onAppear 补建即可，首帧空一拍）。
    @State private var librarySnapshotStore: LibrarySnapshotStore?

    private var librarySnapshotSection: some View {
        Section {
            if let store = librarySnapshotStore {
                LibrarySnapshotPanel(store: store, isIndexing: state.indexing)
            }
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.librarySnapshotSection)
                    .font(DS.Font.displaySection)
            }
        }
        .onAppear {
            if librarySnapshotStore == nil {
                librarySnapshotStore = LibrarySnapshotStore(indexDBURL: state.dbURL)
            }
        }
    }

    private var citationSection: some View {
        Section {
            citationSettingsPanel
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.citationSettingsSection)
                    .font(DS.Font.displaySection)
            }
        }
    }

    // MARK: 索引刷新（RefreshConsoleStore 挂 AppState——

    private var indexRefreshSection: some View {
        Section {
            IndexRefreshPanel(store: state.refreshConsole)
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.indexRefreshSection)
                    .font(DS.Font.displaySection)
            }
        }
    }

    // MARK: 元数据在线补全（总开关默认关 + 逐源四开关；手动唯一）

    private var metadataSection: some View {
        Section {
            Toggle(L10n.metadataFetchToggle, isOn: Binding(
                get: { state.metadataFetchEnabled },
                set: { state.setMetadataFetchEnabled($0) }))
                .accessibilityLabel(L10n.metadataFetchToggle)
            Text(L10n.metadataFetchToggleNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            // 开关由 allCases 驱动（增 openLibrary 自动出现）。
            ForEach(MetadataSource.allCases, id: \.self) { source in
                Toggle(metadataSourceLabel(source), isOn: Binding(
                    get: { state.metadataFetchSourceEnabled(source) },
                    set: { state.setMetadataFetchSource(source, enabled: $0) }))
                    .disabled(!state.metadataFetchEnabled)
                    .accessibilityLabel(metadataSourceLabel(source))
            }
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.metadataSection)
                    .font(DS.Font.displaySection)
            }
        }
    }

    private func metadataSourceLabel(_ source: MetadataSource) -> String {
        switch source {
        case .crossref: return L10n.metadataSourceCrossref
        case .arxiv: return L10n.metadataSourceArxiv
        case .dblp: return L10n.metadataSourceDBLP
        case .semanticScholar: return L10n.metadataSourceSS
        case .openLibrary: return L10n.metadataSourceOpenLibrary
        }
    }

    private var ocrSection: some View {
        Section {
            ocrPanel
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.ocrSection)
                    .font(DS.Font.displaySection)
            }
        }
    }

    private var aiSection: some View {
        Section {
            aiConfigPanel
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.aiSection)
                    .font(DS.Font.displaySection)
            }
        }
    }

    private var syncSection: some View {
        Section {
            syncPanel
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.syncSection)
                    .font(DS.Font.displaySection)
            }
        }
    }

    // MARK: 本机只读 API（开关/端口/令牌/审计环形；服务随开关启停）

    private var localAPISection: some View {
        Section {
            LocalAPIPanel(server: state.localAPIServer,
                          enabled: $state.localAPIEnabled,
                          onCopy: { state.copyString(state.localAPIServer.token) })
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.localAPISection)
                    .font(DS.Font.displaySection)
            }
        }
    }

    // MARK: WebDAV 同步（服务器/凭据 + 三按钮；网络在 AppState 后台跑）

    private var webdavSection: some View {
        Section {
            webdavPanel
        } header: {
            HStack(spacing: DS.Spacing.xs) {
                SealBadge()
                Text(L10n.webdavSection)
                    .font(DS.Font.displaySection)
            }
        }
    }

    private var webdavPanel: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(L10n.webdavPanelNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            HStack(spacing: DS.Spacing.sm) {
                TextField(L10n.webdavServerURL, text: $state.webdavServerBase)
                    .textFieldStyle(.dsTextField)
                TextField(L10n.webdavUsername, text: $state.webdavUsername)
                    .textFieldStyle(.dsTextField)
                    .frame(maxWidth: 220)
            }
            HStack(spacing: DS.Spacing.sm) {
                SecureField(L10n.webdavPassword, text: $state.webdavPassword)
                    .textFieldStyle(.dsTextField)
                    .frame(maxWidth: 260)
                TextField(L10n.webdavRemoteDir, text: $state.webdavRemoteDir)
                    .textFieldStyle(.dsTextField)
                    .frame(maxWidth: 220)
            }
            HStack(spacing: DS.Spacing.sm) {
                Button(L10n.webdavTestConnection) { state.testWebDAVConnection() }
                    .buttonStyle(.bordered)
                    .disabled(state.webdavBusy)
                Button(L10n.webdavPreviewSync) { state.previewWebDAVSync() }
                    .buttonStyle(.bordered)
                    .disabled(state.webdavBusy)
                Button(L10n.webdavSyncNow) { state.syncWebDAVNow() }
                    .buttonStyle(.bordered)
                    .disabled(state.webdavBusy)
            }
            if state.webdavBusy {
                Text(L10n.webdavWorking)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            if !state.webdavStatus.isEmpty {
                Text(state.webdavStatus)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.webdavLocalTarget(state.webdavLocalRootName))
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))

            // 方案一：索引上传（VACUUM INTO 快照 → 白名单 PUT → manifest 提交点）
            Text(L10n.webdavUploadGroupTitle)
                .font(.callout)
            Button(L10n.webdavUploadIndex) { state.uploadIndexToWebDAV() }
                .buttonStyle(.bordered)
                .disabled(state.webdavBusy || state.webdavUploadBusy)
                .accessibilityLabel(L10n.webdavUploadIndex)
            Toggle(L10n.webdavAutoUploadToggle, isOn: $webdavAutoUpload)
                .controlSize(.small)
            Toggle(L10n.webdavCleanupToggle, isOn: $webdavCleanup)
                .controlSize(.small)
            Text(L10n.webdavUploadPrivacyNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                .fixedSize(horizontal: false, vertical: true)
            if state.webdavUploadBusy {
                Text(L10n.webdavUploadInProgress)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }

            // 手机分享收取（PROPFIND inbox 前缀 → 白名单 → 幂等落盘；
            // 手动按钮，禁轮询）。
            Text(L10n.iosInboxGroupTitle)
                .font(.callout)
            Button(L10n.iosInboxPullNow) { state.pullShareInbox() }
                .buttonStyle(.bordered)
                .disabled(state.webdavInboxBusy)
                .accessibilityLabel(L10n.iosInboxPullNow)
            if state.webdavInboxBusy {
                Text(L10n.iosInboxPulling)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            if !state.webdavInboxStatus.isEmpty {
                Text(state.webdavInboxStatus)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !state.webdavUploadStatus.isEmpty {
                Text(state.webdavUploadStatus)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 用户可见审计：最近 5 条（上传会话/逐删记录）。
            Text(L10n.webdavUploadAuditTitle)
                .font(.caption)
            if state.webdavUploadAudit.isEmpty {
                Text(L10n.webdavUploadAuditEmpty)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    ForEach(state.webdavUploadAudit) { entry in
                        Text(Self.auditLine(entry, theme: theme, scheme: scheme))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { state.reloadWebDAVUploadAudit() }
    }

    /// 审计行格式化（明细只含文件名/计数/字节/耗时/结果码——存储本身
    /// 不承载更多字段，见 WebDAVUploadAuditStore）。
    private static func auditLine(_ entry: WebDAVUploadAuditEntry,
                                  theme: DS.Theme, scheme: ColorScheme) -> String {
        let time = WebDAVIndexManifest.iso8601UTC.date(from: entry.at)
            .map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? entry.at
        let detail: String
        switch entry.kind {
        case "upload":
            detail = L10n.webdavUploadAuditUpload(
                entry.volumes ?? 0,
                ByteCountFormatter.string(fromByteCount: entry.bytes ?? 0, countStyle: .file),
                L10n.webdavUploadDurationSeconds((entry.durationMs ?? 0) / 1000),
                entry.result)
        case "cleanup":
            detail = L10n.webdavUploadAuditCleanup(entry.fileName ?? "—", entry.result)
        default:
            detail = L10n.webdavUploadAuditFailed(entry.detail ?? entry.result)
        }
        return L10n.webdavUploadAuditLine(time, detail)
    }

    // MARK: 关于（品牌印记：方印 + 宋体大标题 + 版本与一句话定位）

    private var aboutSection: some View {
        Section {
            VStack(spacing: DS.Spacing.xs) {
                SealBadge(filled: true)
                    .scaleEffect(1.4)
                Text(L10n.appTitle)
                    .font(DS.Font.displayPage)
                Text(appVersion)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                Text(L10n.aboutTagline)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, DS.Spacing.xxl)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    // MARK: 书目列表（版本分组：一版一组；筛选为纯客户端过滤，不读任何书）

    /// Version groups over the filtered library rows: one row per work,
    /// 异版/年版 duplicates collapse behind a badge + expandable pick list.
    private var libraryGroups: [(key: String, primary: IndexStore.BookRow, others: [IndexStore.BookRow])] {
        groupByVersionKey(state.filteredLibraryBooks,
                          fileName: { $0.fileName },
                          id: { $0.id },
                          primaryScore: { $0.pageCount })
    }

    private var booksPanel: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.sm) {
                TextField(L10n.searchBooksPlaceholder, text: $state.libraryBookFilter)
                    .textFieldStyle(.dsTextField)
                    .frame(minWidth: 200)
                Button(L10n.copyAllBookCitations) {
                    state.copyBookCitations(state.filteredLibraryBooks.map {
                        ($0.fileName, $0.title, $0.author, $0.language)
                    })
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.filteredLibraryBooks.isEmpty)
                Button(L10n.copyAllBibtex) {
                    state.copyBooksBibtex(state.filteredLibraryBooks.map {
                        ($0.fileName, $0.title, $0.author, $0.language)
                    })
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.filteredLibraryBooks.isEmpty)
            }
            Text("\(libraryGroups.count) \(L10n.booksUnit)")
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            LazyVStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                ForEach(libraryGroups, id: \.key) { group in
                    LibraryBookGroupRow(group: group)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 引用与检索设置（体例 + 单书命中加载上限；均持久化）

    private var citationSettingsPanel: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            LabeledContent {
                Menu {
                    ForEach(citationStyleSections(), id: \.id) { section in
                        Section(header: Text(section.name)) {
                            ForEach(section.styles, id: \.self) { style in
                                Button {
                                    state.citationStyle = style
                                } label: {
                                    HStack {
                                        Text(style.displayName)
                                        if style == state.citationStyle {
                                            Image(systemName: "checkmark")
                                                .accessibilityHidden(true) // 装饰：选中态由文字述
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Text(state.citationStyle.displayName)
                }
                .menuStyle(.borderedButton)
                .fixedSize()
            } label: {
                Text(L10n.citationStyleLabel).font(.callout)
            }
            HStack(spacing: DS.Spacing.sm) {
                Text(L10n.bookHitsLimitLabel).font(.callout)
                Picker(L10n.bookHitsLimitLabel, selection: $state.bookHitsLimit) {
                    Text("500 \(L10n.pageUnit)").tag(500)
                    Text("1000 \(L10n.pageUnit)").tag(1000)
                    Text("2000 \(L10n.pageUnit)").tag(2000)
                    Text("4000 \(L10n.pageUnit)").tag(4000)
                    Text(L10n.bookHitsLimitUnlimited).tag(0)
                }
                .pickerStyle(.menu)
                .frame(width: 240)
                Text(L10n.bookHitsLimitNote)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 体例分组（中文/英文国际/其他），由 CitationFormatRegistry 驱动。
    private func citationStyleSections() -> [(id: String, name: String, styles: [CitationStyle])] {
        let names: [CitationFormatGroup: String] = [
            .chinese: L10n.styleGroupChinese,
            .englishIntl: L10n.styleGroupEnglish,
            .other: L10n.styleGroupOther,
        ]
        return CitationFormatGroup.allCases.compactMap { group in
            let styles = CitationFormatRegistry.styles(in: group)
            guard !styles.isEmpty, let name = names[group] else { return nil }
            return (id: name, name: name, styles: styles)
        }
    }

    // MARK: Library + indexing (verbatim)

    private var libraryBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            Button(L10n.chooseFolder) { state.chooseFolder() }
                .buttonStyle(.bordered)
            Text(state.rootName ?? L10n.noRootSelected)
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                .lineLimit(1)
            Spacer()
            if state.indexing {
                Button(L10n.cancelIndexing) { state.cancelIndexing() }
                    .buttonStyle(.bordered)
                if let p = state.progress {
                    Text("\(L10n.indexingStatus) \(p.filesDone)/\(p.filesTotal)\(p.currentFile.map { " · \($0)" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                        .lineLimit(1)
                }
            } else {
                Button(L10n.startIndexing) { state.startIndexing() }
                    .buttonStyle(.bordered)
                    .disabled(state.rootName == nil)
            }
        }
    }

    // MARK: OCR pair import (verbatim)

    private var ocrPanel: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Button(L10n.chooseOCRManifest) { state.pickOCRManifest() }
                    .buttonStyle(.bordered)
                Button(L10n.chooseOriginalRoot) { state.chooseOriginalRoot() }
                    .buttonStyle(.bordered)
                Button(L10n.chooseOCRRoot) { state.chooseOCRRoot() }
                    .buttonStyle(.bordered)
            }
            HStack(spacing: DS.Spacing.md) {
                Text(L10n.ocrManifestStatus(state.ocrManifestName ?? L10n.ocrNotSelected,
                                            pairs: state.ocrManifestEntryCount))
                Text(L10n.ocrOriginalRootStatus(state.ocrOriginalRootName))
                Text(L10n.ocrOCRRootStatus(state.ocrOCRRootName))
            }
            .font(.caption)
            .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            HStack(spacing: DS.Spacing.sm) {
                if state.ocrImporting {
                    Button(L10n.cancelOCRImport) { state.cancelOCRImport() }
                        .buttonStyle(.bordered)
                    Text(L10n.ocrImportingStatus).font(.caption).foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                } else {
                    Button(L10n.importOCRPairs) { state.startOCRImport() }
                        .buttonStyle(.bordered)
                        .disabled(state.ocrManifestEntryCount == nil ||
                                  state.ocrOriginalRootName == nil || state.ocrOCRRootName == nil)
                    Button(L10n.verifyOCRPairs) { state.verifyOCRPairs() }
                        .buttonStyle(.bordered)
                }
            }
            if let e = state.ocrManifestError {
                StatusRow(systemImage: "exclamationmark.circle.fill",
                          text: L10n.ocrManifestParseFailed(e), color: DS.Color.error(theme, scheme))
            }
            if let m = state.ocrImportMessage {
                Text(m).font(.caption).foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            if let s = state.ocrImportSummary {
                ForEach(Array(s.outcomes.filter { $0.status != "imported" && $0.status != "verified" && $0.status != "skipped-unchanged" }.enumerated()), id: \.offset) { _, o in
                    StatusRow(systemImage: "exclamationmark.triangle.fill",
                              text: "· \(o.status): \(o.originalPath) ↔ \(o.ocrPath) — \(o.detail)",
                              color: DS.Color.ocr(theme, scheme))
                }
            }
            if let v = state.ocrVerifyMessage {
                Text(v).font(.caption).foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: AI configuration (verbatim; preview/compare moved to detail pane)

    private var aiConfigPanel: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if !state.aiConfigured {
                Text(L10n.aiUnconfigured).font(.caption).foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            } else {
                Text(state.aiMessage).font(.caption).foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            HStack(spacing: DS.Spacing.sm) {
                TextField(L10n.aiServiceURL, text: $state.aiServiceURLString)
                    .textFieldStyle(.dsTextField)
                TextField(L10n.aiModel, text: $state.aiModel)
                    .textFieldStyle(.dsTextField)
                SecureField(L10n.aiAPIKey, text: $state.aiAPIKey)
                    .textFieldStyle(.dsTextField)
                Button(L10n.aiConfigure) { state.configureAI() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Cross-device snapshot (verbatim)

    private var syncPanel: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(L10n.syncSnapshotNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            HStack(spacing: DS.Spacing.sm) {
                Button(L10n.syncExport) { state.exportSnapshot() }
                    .buttonStyle(.bordered)
                Button(L10n.syncImport) { state.importSnapshot() }
                    .buttonStyle(.bordered)
            }
            if !state.syncMessage.isEmpty {
                Text(state.syncMessage).font(.caption2).foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


// MARK: - 版本分组行（书目列表：一版一组）

/// One library work per row: primary book as before; when the group holds
/// 异版/年版 duplicates a badge expands the inline version pick list (each
/// version row opens THAT version's 书目详情).
private struct LibraryBookGroupRow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    let group: (key: String, primary: IndexStore.BookRow, others: [IndexStore.BookRow])
    @State private var versionsShown = false

    var body: some View {
        let theme = DS.Theme.storage(dsTheme)
        let book = group.primary
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Button {
                state.openBookDetail(bookID: book.id)
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Circle()
                        .fill(book.status == "ok" ? DS.Color.success(theme, scheme)
                                                  : DS.Color.warning(theme, scheme))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(book.title ?? book.fileName)
                            .font(.callout)
                            .lineLimit(1)
                        Text(book.author ?? book.fileName)
                            .font(.caption2)
                            .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                            .lineLimit(1)
                    }
                    Spacer(minLength: DS.Spacing.xs)
                    if !group.others.isEmpty {
                        Button {
                            // 动效门：Reduce Motion 下直接切换（无动画）。
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: DS.Motion.hoverDuration)) {
                                versionsShown.toggle()
                            }
                        } label: {
                            CapsuleBadge(text: L10n.otherVersions(group.others.count),
                                         color: DS.Color.inkTertiary(theme, scheme))
                        }
                        .buttonStyle(.plain)
                        .help(L10n.chooseVersionTitle)
                    }
                    Text("\(book.pageCount) \(L10n.pageUnit)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
                .contentShape(Rectangle())
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xxs)
                .paperCard(radius: DS.Radius.small)
            }
            .buttonStyle(.plain)
            if versionsShown && !group.others.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.chooseVersionTitle)
                        .font(.caption2)
                        .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
                        .padding(.leading, DS.Spacing.lg)
                    let all = [group.primary] + group.others
                    ForEach(all, id: \.id) { version in
                        Button {
                            state.openBookDetail(bookID: version.id)
                        } label: {
                            HStack(spacing: DS.Spacing.xs) {
                                if version.id == group.primary.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(DS.Color.ink(theme, scheme))
                                        // 主版徽章有语义。
                                        .accessibilityLabel(L10n.versionPrimaryBadge)
                                }
                                Text(CitationFormatter.cleanFileName(version.fileName))
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer(minLength: DS.Spacing.xs)
                                Text("\(version.pageCount) \(L10n.pageUnit)")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                            }
                            .padding(.horizontal, DS.Spacing.lg)
                            .padding(.vertical, DS.Spacing.xxs)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - 库快照面板（SnapshotManager 备份/恢复入口）

/// 交互与文案沿用设置页既有面板风格：说明行＋主按钮＋快照清单（行尾恢复钮）
/// ＋状态行。恢复钮在索引进行中禁用（活库替换与索引写并发不安全，宁可少做）。
private struct LibrarySnapshotPanel: View {
    @ObservedObject var store: LibrarySnapshotStore
    let isIndexing: Bool
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue

    private var theme: DS.Theme { .storage(dsTheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(L10n.librarySnapshotNote)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            HStack(spacing: DS.Spacing.sm) {
                Button(L10n.librarySnapshotBackup) { store.backup() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.busy)
                    .accessibilityLabel(L10n.librarySnapshotBackup)
            }
            snapshotList
            if !store.message.isEmpty {
                Text(store.message)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(store.message)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 快照清单（listSnapshots 已按名倒序；pre-restore 安全网目录被滤除）。
    @ViewBuilder
    private var snapshotList: some View {
        if store.snapshots.isEmpty {
            Text(L10n.librarySnapshotEmpty)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
        } else {
            ForEach(store.snapshots, id: \.self) { snap in
                HStack(spacing: DS.Spacing.sm) {
                    Text(snap.lastPathComponent)
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    Spacer(minLength: 0)
                    Button(L10n.librarySnapshotRestore) { store.restore(snap) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(store.busy || isIndexing)
                        .accessibilityLabel("\(L10n.librarySnapshotRestore) \(snap.lastPathComponent)")
                }
            }
        }
    }
}

// MARK: - 本机只读 API 面板（设置页「本机 API」区块内容）

/// 开关/状态行/监听地址/令牌一键复制/审计环形（5 条）/说明行。server 可
/// 观察状态直接来自 LocalAPIServer（running/lastError/audit 主线程发布）；
/// 启停只经 enabled 绑定进 AppState（生命周期唯一入口）。
private struct LocalAPIPanel: View {
    @ObservedObject var server: LocalAPIServer
    @Binding var enabled: Bool
    let onCopy: () -> Void
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dsTheme") private var dsTheme = DS.Theme.system.rawValue
    @State private var tokenCopied = false

    private var theme: DS.Theme { .storage(dsTheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Toggle(L10n.localAPIEnable, isOn: $enabled)
            // 状态行：运行中 / 已停止 / fail-closed 显式报错（不静默）。
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: statusSymbol)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            // 监听地址与令牌行不设 running 门（按需启用，不设常开守卫）
            //
            // （端口冲突）或停止态下脚本同样需要取令牌，藏起来即不可用。
            HStack(spacing: DS.Spacing.xs) {
                Text(L10n.localAPIPortLabel)
                    .font(.callout)
                    .foregroundStyle(DS.Color.ink(theme, scheme))
                Text("127.0.0.1:\(LocalAPIServer.defaultPort)")
                    .font(.callout.monospaced())
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
            }
            HStack(spacing: DS.Spacing.sm) {
                Text(L10n.localAPITokenLabel)
                    .font(.callout)
                    .foregroundStyle(DS.Color.ink(theme, scheme))
                Text(server.token)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .help(server.token)
                Button(tokenCopied ? L10n.localAPICopied : L10n.localAPICopy) {
                    onCopy()
                    tokenCopied = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            auditList
            Text(L10n.localAPIExplain)
                .font(.caption2)
                .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
        }
        .padding(.vertical, DS.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusSymbol: String {
        if server.lastError != nil { return "exclamationmark.octagon.fill" }
        return server.running ? "dot.radiowaves.left.and.right" : "stop.circle"
    }

    private var statusColor: Color {
        if server.lastError != nil { return DS.Color.error(theme, scheme) }
        return server.running ? DS.Color.success(theme, scheme) : DS.Color.inkTertiary(theme, scheme)
    }

    private var statusText: String {
        if let error = server.lastError { return error }
        return server.running ? L10n.localAPIRunning : L10n.localAPIStopped
    }

    /// 审计环形：端点/状态码/耗时/字节数（不含查询正文不含令牌——方案 A
    /// 日志纪律）；空环形显式空态。
    @ViewBuilder
    private var auditList: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(L10n.localAPIAudit)
                .font(.caption)
                .foregroundStyle(DS.Color.ink(theme, scheme))
            if server.audit.isEmpty {
                Text(L10n.localAPIAuditEmpty)
                    .font(.caption2)
                    .foregroundStyle(DS.Color.inkTertiary(theme, scheme))
            } else {
                ForEach(server.audit) { entry in
                    Text(L10n.localAPIAuditLine(entry.endpoint, status: entry.status,
                                                milliseconds: entry.milliseconds,
                                                bytes: entry.bytes))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
            }
        }
    }
}

// MARK: - 引擎位置（深度档 / 问答 / 引文跳页共用）
