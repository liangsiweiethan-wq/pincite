import SwiftUI
import LiteratureCore
import LiteratureSearchUI

/// 收藏页（侧栏）：检索式 / 书 / 页 / 句的统一收藏夹。顶部过滤框 +
/// 全部 / 分类 / 标签 分段过滤；分类模式列出既有分类（含「未分类」桶），
/// 标签模式多选标签 chips。行按 kind 展示内容并给出对应动作（打开 / 跳原文 /
/// 复制引注 / 重跑检索）；「整理」模式多选后批量设分类、加标签、删除。
struct FavoritesView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    private enum FilterMode: String, CaseIterable, Identifiable {
        case all, category, tags
        var id: String { rawValue }
    }

    @State private var favorites: [Favorite] = []
    @State private var categories: [String] = []
    @State private var tags: [String] = []
    @State private var filterText = ""
    @State private var mode: FilterMode = .all
    /// nil = 不过滤；"" = 未分类桶。
    @State private var selectedCategory: String? = nil
    @State private var selectedTags: Set<String> = []
    @State private var organizing = false
    @State private var selection: Set<Int64> = []
    @State private var categoryPick = ""
    @State private var newCategoryDraft = ""
    @State private var tagDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            topBar
            if mode == .category {
                categoryChips
            } else if mode == .tags {
                tagChips
            }
            if favorites.isEmpty {
                EmptyStateView(systemImage: "star",
                               title: L10n.favoritesEmpty, detail: "")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                EmptyStateView(systemImage: "line.3.horizontal.decrease.circle",
                               title: L10n.favoritesFilterPlaceholder, detail: "")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { favorite in
                            FavoriteRow(favorite: favorite,
                                        organizing: organizing,
                                        selected: Binding(
                                            get: { selection.contains(favorite.id) },
                                            set: { on in
                                                if on { selection.insert(favorite.id) } else { selection.remove(favorite.id) }
                                            }),
                                        primaryAction: { performPrimaryAction(for: favorite) },
                                        onDeleted: reload)
                                .padding(.horizontal, DS.Spacing.md)
                            Hairline().padding(.leading, DS.Spacing.md)
                        }
                    }
                    .padding(.vertical, DS.Spacing.xs)
                }
            }
            if organizing {
                organizeBar
            }
        }
        .padding(.vertical, DS.Spacing.md)
        // 走查：内容页地面统一 desk token（与检索/历史/覆盖页一致），
        // 收藏行仍为无纸底的 hairline 行。
        .background(DS.Color.desk(theme, scheme))
        .onAppear {
            reload()
            // 应修：冷启动时序下深链先于本视图挂载到达（onChange
            // 只响应变化、首渲染不触发）——onAppear 幂等消费一次已有焦点。
            consumeFavoriteFocus(state.favoriteFocusID)
        }
        // collection 深链 → 行选中（ID 到达即置入整理选中集；
        // 最小语义，实现记录说明）。
        .onChange(of: state.favoriteFocusID) { id in
            consumeFavoriteFocus(id)
        }
    }

    /// 深链焦点消费（onChange 与 onAppear 共用；幂等——消费即清）。
    private func consumeFavoriteFocus(_ id: Int64?) {
        guard let id else { return }
        if favorites.contains(where: { $0.id == id }) {
            selection.insert(id)
        }
        state.favoriteFocusID = nil
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: DS.Spacing.xs) {
            TextField(L10n.favoritesFilterPlaceholder, text: $filterText)
                .textFieldStyle(.dsTextField)
            Picker("", selection: $mode) {
                Text(L10n.favoritesModeAll).tag(FilterMode.all)
                Text(L10n.favoritesModeCategories).tag(FilterMode.category)
                Text(L10n.favoritesModeTags).tag(FilterMode.tags)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Button(organizing ? L10n.favoritesOrganizeDone : L10n.favoritesOrganize) {
                organizing.toggle()
                if !organizing { selection.removeAll() }
            }
            .buttonStyle(.bordered)
            .tint(DS.Color.ink(theme, scheme))
        }
        .padding(.horizontal, DS.Spacing.md)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                chip(title: L10n.favoritesUncategorized, value: "")
                ForEach(categories, id: \.self) { category in
                    chip(title: category, value: category)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
        }
    }

    private func chip(title: String, value: String) -> some View {
        let active = selectedCategory == value
        return Button {
            selectedCategory = active ? nil : value
        } label: {
            Text(title)
                .font(.caption)
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, DS.Spacing.xxs)
                .background(Capsule().fill(active
                    ? DS.Color.ink(theme, scheme)
                    : DS.Color.paper(theme, scheme)))
                .foregroundStyle(active
                    ? DS.Color.paper(theme, scheme)
                    : DS.Color.inkSecondary(theme, scheme))
                .overlay(Capsule().stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(tags, id: \.self) { tag in
                    let active = selectedTags.contains(tag)
                    Button {
                        if active { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
                    } label: {
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, DS.Spacing.xs)
                            .padding(.vertical, DS.Spacing.xxs)
                            .background(Capsule().fill(active
                                ? DS.Color.ink(theme, scheme)
                                : DS.Color.paper(theme, scheme)))
                            .foregroundStyle(active
                                ? DS.Color.paper(theme, scheme)
                                : DS.Color.inkSecondary(theme, scheme))
                            .overlay(Capsule().stroke(DS.Color.stroke(theme, scheme), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Spacing.md)
        }
    }

    // MARK: 整理模式底栏

    private var organizeBar: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Hairline()
            HStack(spacing: DS.Spacing.xs) {
                Menu {
                    Button(L10n.favoritesUncategorized) { categoryPick = "" }
                    ForEach(categories, id: \.self) { category in
                        Button(category) { categoryPick = category }
                    }
                } label: {
                    HStack(spacing: DS.Spacing.xxs) {
                        Text(categoryPick.isEmpty ? L10n.favoritesUncategorized : categoryPick)
                            .font(.caption)
                        Image(systemName: "chevron.down").font(.caption2)
                            .accessibilityHidden(true) // 装饰：菜单展开指示
                    }
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                }
                .fixedSize()
                TextField(L10n.favoritesNewCategoryPlaceholder, text: $newCategoryDraft)
                    .textFieldStyle(.dsTextField)
                    .font(.caption)
                Button(L10n.favoritesCategoryApply) { applyCategory() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selection.isEmpty)
            }
            HStack(spacing: DS.Spacing.xs) {
                TextField(L10n.favoritesTagsPlaceholder, text: $tagDraft)
                    .textFieldStyle(.dsTextField)
                    .font(.caption)
                Button(L10n.favoritesTagsApply) { applyTags() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selection.isEmpty)
                Spacer(minLength: DS.Spacing.xs)
                Button(L10n.actionDelete) { deleteSelected() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selection.isEmpty)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.top, DS.Spacing.xs)
    }

    // MARK: Data

    private func reload() {
        favorites = (try? state.favoritesStore?.all()) ?? []
        categories = (try? state.favoritesStore?.categories()) ?? []
        tags = (try? state.favoritesStore?.tags()) ?? []
    }

    private func applyCategory() {
        let trimmed = newCategoryDraft.trimmingCharacters(in: .whitespaces)
        let category = trimmed.isEmpty ? categoryPick : trimmed
        _ = try? state.favoritesStore?.setCategory(ids: Array(selection), category: category)
        newCategoryDraft = ""
        reload()
    }

    private func applyTags() {
        let newTags = tagDraft
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !newTags.isEmpty else { return }
        _ = try? state.favoritesStore?.addTags(ids: Array(selection), tags: newTags)
        tagDraft = ""
        reload()
    }

    private func deleteSelected() {
        _ = try? state.favoritesStore?.delete(ids: Array(selection))
        selection.removeAll()
        reload()
    }

    private func performPrimaryAction(for favorite: Favorite) {
        switch favorite.target {
        case .book(let bookID, _, _):
            Task { await state.openBookPage(bookID: bookID, pageNumber: 1) }
        case .page(let bookID, _, let pageNumber, _, _, _):
            Task { await state.openBookPage(bookID: bookID, pageNumber: pageNumber) }
        case .quote(_, let fileName, let pageNumber, _):
            state.copyString(CitationFormatter.citation(fileName: fileName, title: nil,
                                                        physicalPage: pageNumber,
                                                        style: state.citationStyle))
        case .search(let query):
            state.query = query
            state.search()
        case .smartSearch(let query, let filter):
            // 智能集合重跑 = 置 query＋filter 四件反向解包到
            // @Published，再走既有 search 管线（现算，零快照）。
            state.filterAuthor = filter?.authorContains ?? ""
            state.filterVersion = filter?.versionContains ?? ""
            state.filterLanguage = filter?.languageEquals ?? ""
            state.filterDomain = filter?.sourceDomain ?? ""
            state.sidebarSection = .search
            state.query = query
            state.search()
        }
    }

    private func filteredContent(_ favorite: Favorite) -> [String] {
        var parts: [String] = [favorite.category] + favorite.tags
        switch favorite.target {
        case .book(_, let fileName, let title):
            parts.append(fileName)
            if let title { parts.append(title) }
        case .page(_, let fileName, _, let snippet, _, _):
            parts.append(fileName); parts.append(snippet)
        case .quote(_, let fileName, _, let sentence):
            parts.append(fileName); parts.append(sentence)
        case .search(let query):
            parts.append(query)
        case .smartSearch(let query, _):
            parts.append(query)
        }
        return parts
    }

    private var filtered: [Favorite] {
        var out = favorites
        switch mode {
        case .all:
            break
        case .category:
            if let selectedCategory {
                out = out.filter {
                    selectedCategory.isEmpty ? $0.category.isEmpty : $0.category == selectedCategory
                }
            }
        case .tags:
            if !selectedTags.isEmpty {
                out = out.filter { !selectedTags.isDisjoint(with: Set($0.tags)) }
            }
        }
        let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            out = out.filter { favorite in
                filteredContent(favorite).contains { $0.lowercased().contains(needle) }
            }
        }
        return out
    }

/// One favorite row: kind icon + kind-specific content + category badge + tags;
/// context menu carries the kind's primary action and delete.
private struct FavoriteRow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dsTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let favorite: Favorite
    let organizing: Bool
    @Binding var selected: Bool
    let primaryAction: () -> Void
    let onDeleted: () -> Void

    private var favoriteKindLabel: String {
        switch favorite.kind {
        case .book: return L10n.favoriteKindBook
        case .page: return L10n.favoriteKindPage
        default: return L10n.favoriteKindQuery
        }
    }

    private var kindIcon: String {
        switch favorite.kind {
        case .book: return "book.closed"
        case .page: return "doc"
        case .quote: return "text.quote"
        case .search: return "magnifyingglass"
        case .smartSearch: return "sparkles.magnifyingglass"
        }
    }

    private var primaryLabel: String {
        switch favorite.kind {
        case .book: return L10n.favoritesOpenBook
        case .page: return L10n.favoritesJumpToPage
        case .quote: return L10n.favoritesCopyCitation
        case .search: return L10n.favoritesRerunSearch
        case .smartSearch: return L10n.favoritesRerunSearch
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.xs) {
            if organizing {
                Toggle("", isOn: $selected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .padding(.top, DS.Spacing.xxs)
            }
            Image(systemName: kindIcon)
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                .frame(width: 16)
                .padding(.top, DS.Spacing.xxs)
                // 类型图标有语义（书/页/检索式），VoiceOver 报类型。
                .accessibilityLabel(favoriteKindLabel)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                rowContent
                HStack(spacing: DS.Spacing.xxs) {
                    if !favorite.category.isEmpty {
                        CapsuleBadge(text: favorite.category,
                                     color: DS.Color.inkSecondary(theme, scheme))
                    }
                    ForEach(favorite.tags, id: \.self) { tag in
                        CapsuleBadge(text: tag, color: DS.Color.inkTertiary(theme, scheme))
                    }
                }
            }
        }
        .padding(.vertical, DS.Spacing.md)
        .contentShape(Rectangle())
        .dsHoverFade()
        .contextMenu {
            Button(primaryLabel, action: primaryAction)
            Divider()
            Button(L10n.actionDelete) {
                _ = try? state.favoritesStore?.delete(ids: [favorite.id])
                onDeleted()
            }
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        switch favorite.target {
        case .book(_, let fileName, let title):
            Text(title ?? fileName)
                .font(DS.Font.displayGroup)
                .lineLimit(1)
            if title != nil {
                Text(fileName)
                    .font(.caption)
                    .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                    .lineLimit(1)
            }
        case .page(_, let fileName, let pageNumber, let snippet, _, _):
            Text("\(fileName) · \(L10n.favoritesPageLine(pageNumber))")
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                .lineLimit(1)
            Text(snippet)
                .font(.callout)
                .foregroundStyle(DS.Color.ink(theme, scheme))
                .lineLimit(2)
        case .quote(_, let fileName, let pageNumber, let sentence):
            Text(sentence)
                .font(DS.Font.readingSerif())
                .foregroundStyle(DS.Color.ink(theme, scheme))
                .lineLimit(3)
            Text("\(fileName) · \(L10n.quoteCitation(fileName, page: pageNumber))")
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                .lineLimit(1)
        case .search(let query):
            Text(query)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(DS.Color.ink(theme, scheme))
                .lineLimit(2)
        case .smartSearch(let query, let filter):
            // 查询串＋「智能集合」标注＋条件摘要。
            Text(query)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(DS.Color.ink(theme, scheme))
                .lineLimit(2)
            Text(L10n.smartCollectionSummary(Self.filterSummary(filter)))
                .font(.caption)
                .foregroundStyle(DS.Color.inkSecondary(theme, scheme))
                .lineLimit(1)
        }
    }

    /// 智能集合条件摘要（filter → 人话；nil/全空 = 无条件）。
    static func filterSummary(_ filter: SearchFilter?) -> String {
        guard let filter else { return "" }
        var parts: [String] = []
        if let a = filter.authorContains { parts.append(L10n.smartCollectionCondAuthor(a)) }
        if let v = filter.versionContains { parts.append(L10n.smartCollectionCondVersion(v)) }
        if let l = filter.languageEquals { parts.append(L10n.smartCollectionCondLanguage(l)) }
        if let d = filter.sourceDomain {
            parts.append(d == "paper" ? L10n.smartCollectionCondPaper : L10n.smartCollectionCondBook)
        }
        return parts.joined(separator: " · ")
    }
}
}
