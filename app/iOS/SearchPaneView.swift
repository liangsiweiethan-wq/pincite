import SwiftUI

// MARK: - 检索页（matchingBooks 书目级聚合先行，searchDetailed
// 页级展开——与桌面两段式同构；检索语义层零触碰）

struct SearchPaneView: View {
    @EnvironmentObject var model: LibraryModel
    @State private var query = ""
    @State private var results: [SearchService.BookHitSummary] = []
    @State private var errorMessage = ""
    @State private var expandedBookID: String?
    @State private var detailHits: [SearchHit] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.searchPlaceholder, text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .onSubmit(runSearch)
                if !query.isEmpty {
                    Button(L10n.aiCancelSend) { query = ""; results = []; detailHits = [] }
                        .buttonStyle(.borderless)
                }
            }
            .padding(12)
            .background(.bar)

            if !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(.red).padding(8)
            }
            if results.isEmpty {
                ContentUnavailableCompat(title: L10n.iosSearchEmptyTitle,
                                         detail: model.replicaState == .ready
                                            ? L10n.iosSearchEmptyDetail
                                            : L10n.iosReplicaMissingDetail)
            } else {
                List {
                    ForEach(results, id: \.bookID) { book in
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                toggleExpand(book)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(book.title ?? book.fileName).font(.body)
                                        Text(L10n.iosBookHits(book.matchingPages))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: expandedBookID == book.bookID
                                          ? "chevron.up" : "chevron.down")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            if expandedBookID == book.bookID {
                                ForEach(detailHits, id: \.self) { hit in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(hit.snippet.isEmpty
                                             ? L10n.iosHitPageOnly(hit.physicalPage)
                                             : hit.snippet)
                                            .font(.caption)
                                            .lineLimit(3)
                                        Text(L10n.iosHitPageLabel(hit.physicalPage))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func runSearch() {
        errorMessage = ""
        detailHits = []
        expandedBookID = nil
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            results = try model.matchingBooks(query)
        } catch {
            results = []
            errorMessage = String(describing: error)
        }
    }

    private func toggleExpand(_ book: SearchService.BookHitSummary) {
        if expandedBookID == book.bookID {
            expandedBookID = nil
            detailHits = []
            return
        }
        expandedBookID = book.bookID
        do {
            detailHits = try model.detailedHits(query, bookID: book.bookID)
        } catch {
            detailHits = []
            errorMessage = String(describing: error)
        }
    }
}
