import Foundation

// MARK: - Reference resolution (input IDs only; out-of-scope refs rejected)
//
// References returned by an AI response may only point at books that were part
// of the request input context and pages inside that book's indexed range.
// Anything else is rejected with a reason — never silently widened.

public struct AllowedSource: Equatable {
    public var bookID: String
    public var pageCount: Int
    public var fingerprint: String

    public init(bookID: String, pageCount: Int, fingerprint: String) {
        self.bookID = bookID
        self.pageCount = pageCount
        self.fingerprint = fingerprint
    }
}

public enum ReferenceDecision: Equatable {
    case accepted(bookID: String, physicalPage: Int)
    case rejected(bookID: String, page: Int, reason: String)
}

public enum ReferenceResolver {
    /// Validates references strictly against the allowed input sources.
    public static func resolve(_ references: [AIReference], allowedSources: [AllowedSource]) -> [ReferenceDecision] {
        let byID = Dictionary(allowedSources.map { ($0.bookID, $0) }, uniquingKeysWith: { a, _ in a })
        return references.map { ref in
            guard let source = byID[ref.bookId] else {
                return .rejected(bookID: ref.bookId, page: ref.page, reason: "unknown-book-id (not part of request input)")
            }
            guard ref.page >= 1 else {
                return .rejected(bookID: ref.bookId, page: ref.page, reason: "page out of range (pages are 1-based)")
            }
            guard ref.page <= source.pageCount else {
                return .rejected(bookID: ref.bookId, page: ref.page, reason: "page out of range (book has \(source.pageCount) pages)")
            }
            if let echoed = ref.fingerprint, echoed != source.fingerprint {
                return .rejected(bookID: ref.bookId, page: ref.page, reason: "stale reference (fingerprint mismatch)")
            }
            return .accepted(bookID: ref.bookId, physicalPage: ref.page)
        }
    }
}
