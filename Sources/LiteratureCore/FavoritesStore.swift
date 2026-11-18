import Foundation


public enum FavoriteKind: String, Codable, CaseIterable, Sendable {
    case book, page, quote, search
    /// 智能收藏（query＋filter 的动态集合；只加不改，.search 旧
    /// case 关联值与行为逐字不动）。
    case smartSearch
}

public enum FavoriteTarget: Equatable, Sendable {
    case book(bookID: String, fileName: String, title: String?)
    case page(bookID: String, fileName: String, pageNumber: Int, snippet: String,
               utf16Start: Int?, utf16End: Int?)
    case quote(bookID: String, fileName: String, pageNumber: Int, sentence: String)
    case search(query: String)
    /// 智能收藏——查询串＋完整过滤条件；filter=nil 等价无条件。
    /// 集合存条件本身，消费侧每次现算（SmartCollections.evaluate）。
    case smartSearch(query: String, filter: SearchFilter?)

    public var kind: FavoriteKind {
        switch self {
        case .book: return .book
        case .page: return .page
        case .quote: return .quote
        case .search: return .search
        case .smartSearch: return .smartSearch
        }
    }
}

extension FavoriteTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, bookID, fileName, title, pageNumber, snippet, sentence, query
        case utf16Start, utf16End
        case filter   // smartSearch 的过滤条件（可缺省，旧 JSON 兼容）
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let kind = try FavoriteKind(rawValue: c.decode(String.self, forKey: .kind)) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "unknown favorite kind")
        }
        switch kind {
        case .book:
            self = .book(bookID: try c.decode(String.self, forKey: .bookID),
                         fileName: try c.decode(String.self, forKey: .fileName),
                         title: try c.decodeIfPresent(String.self, forKey: .title))
        case .page:
            self = .page(bookID: try c.decode(String.self, forKey: .bookID),
                         fileName: try c.decode(String.self, forKey: .fileName),
                         pageNumber: try c.decode(Int.self, forKey: .pageNumber),
                         snippet: try c.decode(String.self, forKey: .snippet),
                         utf16Start: try c.decodeIfPresent(Int.self, forKey: .utf16Start),
                         utf16End: try c.decodeIfPresent(Int.self, forKey: .utf16End))
        case .quote:
            self = .quote(bookID: try c.decode(String.self, forKey: .bookID),
                          fileName: try c.decode(String.self, forKey: .fileName),
                          pageNumber: try c.decode(Int.self, forKey: .pageNumber),
                          sentence: try c.decode(String.self, forKey: .sentence))
        case .search:
            self = .search(query: try c.decode(String.self, forKey: .query))
        case .smartSearch:
            // filter 键缺失（旧形态/无过滤）解出 nil，decodeIfPresent 保旧 JSON 兼容。
            self = .smartSearch(query: try c.decode(String.self, forKey: .query),
                                filter: try c.decodeIfPresent(SearchFilter.self, forKey: .filter))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .kind)
        switch self {
        case .book(let bookID, let fileName, let title):
            try c.encode(bookID, forKey: .bookID)
            try c.encode(fileName, forKey: .fileName)
            try c.encodeIfPresent(title, forKey: .title)
        case .page(let bookID, let fileName, let pageNumber, let snippet, let utf16Start, let utf16End):
            try c.encode(bookID, forKey: .bookID)
            try c.encode(fileName, forKey: .fileName)
            try c.encode(pageNumber, forKey: .pageNumber)
            try c.encode(snippet, forKey: .snippet)
            try c.encodeIfPresent(utf16Start, forKey: .utf16Start)
            try c.encodeIfPresent(utf16End, forKey: .utf16End)
        case .quote(let bookID, let fileName, let pageNumber, let sentence):
            try c.encode(bookID, forKey: .bookID)
            try c.encode(fileName, forKey: .fileName)
            try c.encode(pageNumber, forKey: .pageNumber)
            try c.encode(sentence, forKey: .sentence)
        case .search(let query):
            try c.encode(query, forKey: .query)
        case .smartSearch(let query, let filter):
            try c.encode(query, forKey: .query)
            try c.encodeIfPresent(filter, forKey: .filter)
        }
    }
}

public struct Favorite: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let kind: FavoriteKind
    public let target: FavoriteTarget
    public var category: String
    public var tags: [String]
    public let createdAt: Date
}

public final class FavoritesStore {
    private let indexStore: IndexStore
    private let lock = NSLock()

    public init(indexStore: IndexStore) {
        self.indexStore = indexStore
    }

    public func add(_ target: FavoriteTarget, category: String = "", tags: [String] = []) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let db = indexStore.db
        let data = try JSONEncoder().encode(target)
        let stmt = try db.prepare("""
            INSERT INTO favorites(kind, target_json, category, tags, created_at)
            VALUES(?, ?, ?, ?, ?);
            """)
        defer { stmt.reset() }
        try stmt.bindText(1, target.kind.rawValue)
        try stmt.bindText(2, String(decoding: data, as: UTF8.self))
        try stmt.bindText(3, category)
        try stmt.bindText(4, tags.joined(separator: ","))
        try stmt.bindDouble(5, Date().timeIntervalSince1970)
        try stmt.run()
        return stmt.lastInsertRowid
    }

    /// Stable manual order: creation order (createdAt ascending, then id).
    public func all() throws -> [Favorite] {
        try query("SELECT * FROM favorites ORDER BY created_at, id;")
    }

    public func favorites(kind: FavoriteKind) throws -> [Favorite] {
        try query("SELECT * FROM favorites WHERE kind = ? ORDER BY created_at, id;") { stmt in
            try stmt.bindText(1, kind.rawValue)
        }
    }

    public func categories() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let db = indexStore.db
        let stmt = try db.prepare("""
            SELECT DISTINCT category FROM favorites WHERE category != '' ORDER BY category;
            """)
        defer { stmt.reset() }
        var out: [String] = []
        while try stmt.step() { out.append(stmt.text(0)) }
        return out
    }

    public func tags() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let db = indexStore.db
        let stmt = try db.prepare("SELECT tags FROM favorites WHERE tags != '';")
        defer { stmt.reset() }
        var seen = Set<String>()
        while try stmt.step() {
            for tag in stmt.text(0).split(separator: ",") {
                seen.insert(String(tag))
            }
        }
        return seen.sorted()
    }

    public func setCategory(ids: [Int64], category: String) throws {
        lock.lock(); defer { lock.unlock() }
        let db = indexStore.db
        let stmt = try db.prepare("UPDATE favorites SET category = ? WHERE id = ?;")
        defer { stmt.reset() }
        for id in ids {
            try stmt.bindText(1, category)
            try stmt.bindInt(2, id)
            try stmt.run()
            stmt.reset()
            stmt.clearBindings()
        }
    }

    /// Merge-union: existing tags are kept, new ones appended, order-preserving.
    public func addTags(ids: [Int64], tags: [String]) throws {
        guard !tags.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let db = indexStore.db
        let select = try db.prepare("SELECT tags FROM favorites WHERE id = ?;")
        defer { select.reset() }
        let update = try db.prepare("UPDATE favorites SET tags = ? WHERE id = ?;")
        defer { update.reset() }
        for id in ids {
            try select.bindInt(1, id)
            guard try select.step() else {
                select.reset(); select.clearBindings()
                continue
            }
            var merged = select.text(0).split(separator: ",").map(String.init)
            for tag in tags where !merged.contains(tag) {
                merged.append(tag)
            }
            select.reset(); select.clearBindings()
            try update.bindText(1, merged.joined(separator: ","))
            try update.bindInt(2, id)
            try update.run()
            update.reset(); update.clearBindings()
        }
    }

    public func delete(ids: [Int64]) throws {
        lock.lock(); defer { lock.unlock() }
        let db = indexStore.db
        let stmt = try db.prepare("DELETE FROM favorites WHERE id = ?;")
        defer { stmt.reset() }
        for id in ids {
            try stmt.bindInt(1, id)
            try stmt.run()
            stmt.reset()
            stmt.clearBindings()
        }
    }

    // MARK: Internals

    private func query(_ sql: String, bind: (SQLiteDatabase.Statement) throws -> Void = { _ in }) throws -> [Favorite] {
        lock.lock(); defer { lock.unlock() }
        let db = indexStore.db
        let stmt = try db.prepare(sql)
        defer { stmt.reset() }
        try bind(stmt)
        var out: [Favorite] = []
        while try stmt.step() {
            let targetJSON = stmt.text(2)
            let target = try JSONDecoder().decode(FavoriteTarget.self,
                                                  from: Data(targetJSON.utf8))
            out.append(Favorite(
                id: stmt.int(0),
                kind: target.kind,
                target: target,
                category: stmt.text(3),
                tags: stmt.text(4).split(separator: ",").map(String.init),
                createdAt: Date(timeIntervalSince1970: stmt.double(5))))
        }
        return out
    }
}
