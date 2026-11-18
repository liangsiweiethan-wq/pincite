import Foundation

// MARK: - 版本去重聚合
//
// Every physical PDF — including `…_异版hash.pdf` variants — is its own row in
// `books`, so a library with several scans/editions of the same work surfaced
// it multiple times in search and in the book list. This layer groups those
// rows into one version group keyed by a normalized file name, so a work is
// searched for and displayed ONCE. Matching semantics are untouched — this is
// purely an aggregation over `BookHitSummary` results.
//
// The normalizer intentionally mirrors CitationFormatter.cleanFileName (the
// UI module cannot be imported from Core — Package.swift: UI depends on Core),
// and additionally strips trailing year / edition suffixes so that
// 「书名同+年份同」 and「互为异版」 land in one group.

/// Normalizes a library file name into a version-group key:
    /// strips extension, synthetic edition/hash suffixes, configurable noise parentheticals,
/// trailing year `(19|20)\d{2}` and edition-ish suffixes
/// (`第N版`/`N版`/`修订版`/`增订版`/`第N修订版`/`修订本`/`增订本`, also when
/// parenthesized), then lowercases and removes all punctuation/whitespace.
public func versionGroupKey(fileName: String) -> String {
    var n = fileName
    for ext in [".pdf", ".PDF", ".Pdf"] where n.hasSuffix(ext) {
        n = String(n.dropLast(ext.count))
    }
    if let r = n.range(of: "_异版[0-9A-Za-z]{6,8}$", options: .regularExpression) {
        n = n.replacingCharacters(in: r, with: "")
    }
    if let r = n.range(of: "[(（]\\s*(第[0-9一二三四五六七八九十百]+修订版|第[0-9一二三四五六七八九十百]+版|[0-9一二三四五六七八九十百]+版|修订版|增订版|修订本|增订本)\\s*[)）]\\s*$", options: .regularExpression) {
        n = String(n[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let suffixes = [
        "[(（]?\\s*(19|20)\\d{2}\\s*[)）]?\\s*$",
        "(第[0-9一二三四五六七八九十百]+修订版|第[0-9一二三四五六七八九十百]+版|[0-9一二三四五六七八九十百]+版|修订版|增订版|修订本|增订本)\\s*$",
    ]
    var changed = true
    while changed {
        changed = false
        for pattern in suffixes {
            if let r = n.range(of: pattern, options: .regularExpression) {
                n = String(n[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
    }
    // Lowercase, then keep only letters and digits (drops punctuation and
    // whitespace in every script, CJK included).
    return String(n.lowercased().filter { $0.isLetter || $0.isNumber })
}

/// One work = one group. `primary` is the representative row (most native-text
/// pages; tie → shorter fileName; tie → bookID — a stable total order).
/// `others` holds the remaining versions sorted by fileName for determinism.
public struct BookVersionGroup: Identifiable, Equatable {
    public var id: String { groupKey }
    public let groupKey: String
    public let primary: SearchService.BookHitSummary
    public let others: [SearchService.BookHitSummary]

    /// The group's match-page count is the PRIMARY's count — other versions
    /// never add to it (no double counting across a work).
    public var matchingPages: Int { primary.matchingPages }

    public init(groupKey: String, primary: SearchService.BookHitSummary, others: [SearchService.BookHitSummary]) {
        self.groupKey = groupKey
        self.primary = primary
        self.others = others
    }
}

/// Groups book-level search summaries into version groups, preserving the
/// first-appearance order of groups. Within a group the primary is chosen by
/// max nativeTextPages, then shorter fileName, then bookID (stable regardless
/// of input order); the rest become `others` sorted by fileName.
public func aggregateVersionGroups(_ summaries: [SearchService.BookHitSummary]) -> [BookVersionGroup] {
    var order: [String] = []
    var buckets: [String: [SearchService.BookHitSummary]] = [:]
    for s in summaries {
        let key = versionGroupKey(fileName: s.fileName)
        if buckets[key] == nil { order.append(key) }
        buckets[key, default: []].append(s)
    }
    func isPrimary(_ a: SearchService.BookHitSummary, _ b: SearchService.BookHitSummary) -> Bool {
        if a.nativeTextPages != b.nativeTextPages { return a.nativeTextPages > b.nativeTextPages }
        if a.fileName.count != b.fileName.count { return a.fileName.count < b.fileName.count }
        return a.bookID < b.bookID
    }
    return order.map { key in
        let all = buckets[key] ?? []
        let primary = all.count == 1 ? all[0] : all.dropFirst().reduce(all[0]) { isPrimary($1, $0) ? $1 : $0 }
        let others = all
            .filter { $0.bookID != primary.bookID }
            .sorted { $0.fileName != $1.fileName ? $0.fileName < $1.fileName : $0.bookID < $1.bookID }
        return BookVersionGroup(groupKey: key, primary: primary, others: others)
    }
}

/// Total match-page count across groups (each work counted once — via its
/// primary). Compare against a naive sum over all summaries to prove the
/// aggregation removed no hits from display while stopping double counting.
public func totalMatchingPagesAcrossGroups(_ groups: [BookVersionGroup]) -> Int {
    groups.reduce(0) { $0 + $1.matchingPages }
}

/// Generic version-grouping for non-search rows that still carry a fileName
/// (the library list groups `IndexStore.BookRow` the same way). Primary is
/// max `primaryScore`, tie → shorter fileName, tie → `id`.
public func groupByVersionKey<T>(_ items: [T], fileName: (T) -> String, id: (T) -> String,
                                 primaryScore: (T) -> Int) -> [(key: String, primary: T, others: [T])] {
    var order: [String] = []
    var buckets: [String: [T]] = [:]
    for item in items {
        let key = versionGroupKey(fileName: fileName(item))
        if buckets[key] == nil { order.append(key) }
        buckets[key, default: []].append(item)
    }
    func isPrimary(_ a: T, _ b: T) -> Bool {
        let sa = primaryScore(a), sb = primaryScore(b)
        if sa != sb { return sa > sb }
        let fa = fileName(a), fb = fileName(b)
        if fa.count != fb.count { return fa.count < fb.count }
        return id(a) < id(b)
    }
    return order.map { key in
        let all = buckets[key] ?? []
        let primary = all.count == 1 ? all[0] : all.dropFirst().reduce(all[0]) { isPrimary($1, $0) ? $1 : $0 }
        let others = all
            .filter { id($0) != id(primary) }
            .sorted { fileName($0) != fileName($1) ? fileName($0) < fileName($1) : id($0) < id($1) }
        return (key, primary, others)
    }
}
