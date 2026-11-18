import Foundation

// MARK: - Search normalization (index/query time only; display keeps the original)

/// Result of search-side normalization of an original string.
///
/// The *display* text is always the original page text, untouched.
/// The *search* text is a normalized derivative, and `map` lets us translate
/// match ranges in the normalized string back to UTF-16 offsets in the original
/// string (used for programmatic location of the match on the PDF page).
public struct NormalizedText {
    public let text: String
    /// For each output character: UTF-16 offset of its source character in the original string.
    public let starts: [Int32]
    /// For each output character: UTF-16 end offset of its source character in the original string.
    public let ends: [Int32]

    public var isEmpty: Bool { text.isEmpty }

    /// Translates a range (String.Index based) in the normalized text into a
    /// UTF-16 range in the original text. Returns nil when out of bounds.
    public func originalUTF16Range(_ range: Range<String.Index>) -> Range<Int>? {
        let chars = text
        guard range.lowerBound >= chars.startIndex, range.upperBound <= chars.endIndex else { return nil }
        let lower = chars.distance(from: chars.startIndex, to: range.lowerBound)
        let upper = chars.distance(from: chars.startIndex, to: range.upperBound)
        guard lower < starts.count else { return nil }
        let upperIndex = min(max(upper - 1, 0), ends.count - 1)
        return Int(starts[lower])..<Int(ends[upperIndex])
    }
}

/// Search normalization rules (applied identically at index time and query time):
/// 1. Unicode NFKC compatibility decomposition (unifies full/half width, e.g. 「ＡＢＣ」→「abc」, ligatures like 「ﬁ」→「fi」).
/// 2. NFD canonical decomposition to isolate combining diacritical marks.
/// 3. Strip combining diacritical marks (Mn range U+0300..U+036F, e.g. 「für」→「fur」, 「búsqueda」→「busqueda」).
/// 4. Unicode case folding via lowercased (English case-insensitive; CJK unaffected).
/// 5. Sharp S folding: 「ß」/「ẞ」→「ss」 (e.g. 「straße」→「strasse」).
/// 6. Remove zero-width characters and soft hyphens (U+00AD).
/// 7. Collapse any run of whitespace into a single ASCII space.
///
/// The original text is never modified for display; this mapping exists only so
/// that matches found in the normalized text can be located in the original.
public func normalizeForSearch(_ original: String) -> NormalizedText {
    var outChars: [Character] = []
    var starts: [Int32] = []
    var ends: [Int32] = []

    var utf16Offset = 0
    for ch in original {
        let sourceStart = utf16Offset
        utf16Offset += String(ch).utf16.count
        let sourceEnd = utf16Offset

        // Skip zero-width characters and soft hyphen entirely.
        if ch.isZeroWidthOrSoftHyphen { continue }

        var expanded: String
        if ch.isWhitespaceOrNewline {
            // Collapse whitespace runs to a single space.
            if outChars.last.map({ $0 == " " }) == true { continue }
            expanded = " "
        } else {
            // 1. Compatibility mapping (NFKC)
            let nfkc = String(ch).precomposedStringWithCompatibilityMapping
            // 2. NFD canonical decomposition to isolate combining diacritical marks
            let nfd = nfkc.decomposedStringWithCanonicalMapping
            // 3. Strip Mn combining diacritical marks (0x0300-0x036F)
            let strippedScalars = nfd.unicodeScalars.filter { !($0.value >= 0x0300 && $0.value <= 0x036F) }
            let stripped = String(String.UnicodeScalarView(strippedScalars))
            // 4. Unicode case folding
            var folded = stripped.lowercased()
            // 5. German sharp S folding: ß -> ss (capital ẞ lowercases to ß in step 4)
            folded = folded.replacingOccurrences(of: "ß", with: "ss")
            expanded = folded
        }

        for out in expanded {
            outChars.append(out)
            starts.append(Int32(sourceStart))
            ends.append(Int32(sourceEnd))
        }
    }

    return NormalizedText(text: String(outChars), starts: starts, ends: ends)
}

extension Character {
    var isZeroWidthOrSoftHyphen: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        switch scalar.value {
        case 0x00AD, // soft hyphen
             0x200B, 0x200C, 0x200D, // zero width space / non-joiner / joiner
             0xFEFF: // BOM / zero width no-break space
            return true
        default:
            return false
        }
    }

    var isWhitespaceOrNewline: Bool {
        unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}

// MARK: - Query normalization + matching helpers

/// Normalizes a user query with the same rules as page text.
public func normalizeQuery(_ query: String) -> String {
    normalizeForSearch(query).text.trimmingCharacters(in: .whitespaces)
}

/// Splits a normalized query into literal search terms (whitespace separated).
/// Terms are matched literally — never interpreted as FTS syntax or regex.
public func splitQueryTerms(_ normalizedQuery: String) -> [String] {
    normalizedQuery.split(whereSeparator: { $0 == " " }).map(String.init).filter { !$0.isEmpty }
}

/// Escapes a literal term for SQL LIKE with ESCAPE '\'.
public func escapeForLike(_ term: String) -> String {
    var out = ""
    for ch in term {
        if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
        out.append(ch)
    }
    return out
}

/// Wraps a literal term as a quoted FTS5 string so token characters in the
/// term are never parsed as query syntax.
public func quoteForFTS(_ term: String) -> String {
    "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
