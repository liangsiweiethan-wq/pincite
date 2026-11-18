import Foundation

// MARK: - Exclusion policy
//
// Index only PDFs within the selected root and apply the user's exclusion rules.
public enum ExclusionConfigError: Error, CustomStringConvertible {
    case malformed(String)
    public var description: String {
        switch self {
        case .malformed(let reason): return "exclusion config malformed: \(reason) (fail-closed: fix the file or delete it)"
        }
    }
}

public struct ExclusionConfig: Codable, Equatable {
    /// Substrings; if any appears in the candidate's path or file name -> excluded.
    public var excludedPathSubstrings: [String]
    /// Glob patterns matched against the root-relative path ('*', '**', '?').
    public var excludedGlobs: [String]
    /// Book identifiers to exclude.
    public var excludedBookIDs: [String]
    /// User-defined identifier substrings (ID + path matching), auditable and editable.
    public var excludedIdentifiers: [String]

    public init(excludedPathSubstrings: [String] = [],
                excludedGlobs: [String] = [],
                excludedBookIDs: [String] = [],
                excludedIdentifiers: [String] = []) {
        self.excludedPathSubstrings = excludedPathSubstrings
        self.excludedGlobs = excludedGlobs
        self.excludedBookIDs = excludedBookIDs
        self.excludedIdentifiers = excludedIdentifiers
    }

    /// Missing fields become empty arrays so older configurations still decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func array(_ key: CodingKeys) throws -> [String] {
            guard container.contains(key) else { return [] }
            let values = try container.decode([String].self, forKey: key)
            return values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        excludedPathSubstrings = try array(.excludedPathSubstrings)
        excludedGlobs = try array(.excludedGlobs)
        excludedBookIDs = try array(.excludedBookIDs)
        excludedIdentifiers = try array(.excludedIdentifiers)
    }

    private enum CodingKeys: String, CodingKey {
        case excludedPathSubstrings, excludedGlobs, excludedBookIDs, excludedIdentifiers
    }

    /// Default configuration for libraries without an exclusions.json file.
    public static let conservativeDefaults = ExclusionConfig()

    /// Fail-closed loader: a missing file yields the conservative defaults; a
    /// malformed file THROWS and the caller must block indexing — it never
    /// silently falls back to an empty (permissive) configuration.
    public static func loadForOperation(fileAt url: URL) throws -> ExclusionConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return conservativeDefaults
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ExclusionConfigError.malformed("cannot read \(url.lastPathComponent): \(error)")
        }
        return try decode(from: data) // throws on malformed JSON/schema
    }

    /// Loads a config file when present; otherwise conservative defaults apply.
    public static func loadOrDefault(fileAt url: URL) -> ExclusionConfig {
        if FileManager.default.fileExists(atPath: url.path) {
            return ExclusionConfig.load(from: url)
        }
        return conservativeDefaults
    }

    /// Loads a user exclusion config from JSON; missing file -> empty additions.
    /// Tolerant loader for non-security display purposes. Operational paths
    /// MUST use `loadForOperation` (fail-closed) instead.
    public static func load(from url: URL) -> ExclusionConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ExclusionConfig.self, from: data) else {
            return ExclusionConfig()
        }
        return config
    }

    /// Strict decode used by operational paths; malformed input throws.
    public static func decode(from data: Data) throws -> ExclusionConfig {
        do {
            return try JSONDecoder().decode(ExclusionConfig.self, from: data)
        } catch {
            throw ExclusionConfigError.malformed(String(describing: error))
        }
    }
}

public enum ExclusionVerdict: Equatable {
    case allowed
    case excludedByPathSubstring(String)
    case excludedByGlob(String)
    case excludedByID(String)                   // configured book ID list
    case symlinkEscape
    case unsupportedFileType
}

public struct ExclusionPolicy {
    public let config: ExclusionConfig

    public init(config: ExclusionConfig = ExclusionConfig()) {
        self.config = config
    }

    public var effectiveSubstrings: [String] {
        config.excludedPathSubstrings + config.excludedIdentifiers
    }
    public var effectiveBookIDs: [String] { config.excludedBookIDs + config.excludedIdentifiers }
    public var effectiveGlobs: [String] { config.excludedGlobs }

    /// Evaluates a candidate file under `rootURL`.
    /// `isPDFBundle` is false: plain .pdf files only.
    public func evaluate(candidateFileURL: URL, rootURL: URL) -> ExclusionVerdict {
        // Only PDFs are indexed (plain files; no .pdf bundle directories).
        guard candidateFileURL.pathExtension.lowercased() == "pdf" else {
            return .unsupportedFileType
        }

        let realCandidate = candidateFileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let realRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = realRoot == "/" ? realRoot : realRoot + "/"

        // Symlink escape: the resolved physical location must stay inside the
        // resolved root. This blocks symlink/symlinked-ancestor escapes.
        if realCandidate != realRoot, !realCandidate.hasPrefix(rootPrefix) {
            return .symlinkEscape
        }

        for needle in effectiveSubstrings where !needle.isEmpty {
            if candidateFileURL.path.localizedCaseInsensitiveContains(needle)
                || realCandidate.localizedCaseInsensitiveContains(needle) {
                return .excludedByPathSubstring(needle)
            }
        }

        if !effectiveGlobs.isEmpty {
            let path = candidateFileURL.path
            let relative = path.hasPrefix(rootURL.path + "/")
                ? String(path.dropFirst(rootURL.path.count + 1))
                : candidateFileURL.lastPathComponent
            let realRelative = String(realCandidate.dropFirst(rootPrefix.count))
            let realName = (realCandidate as NSString).lastPathComponent
            let paths = [relative, candidateFileURL.lastPathComponent, realRelative, realName]
            for glob in effectiveGlobs where !glob.isEmpty
                && paths.contains(where: { GlobMatcher.matches(path: $0, pattern: glob) }) {
                return .excludedByGlob(glob)
            }
        }

        return .allowed
    }

    /// Post-extraction check on the assigned book ID (covers IDs derived from
    /// the excluded book even when the file name was sanitized).
    public func evaluateBookID(_ bookID: String) -> ExclusionVerdict {
        for id in effectiveBookIDs where !id.isEmpty {
            if bookID.localizedCaseInsensitiveContains(id) {
                return .excludedByID(id)
            }
        }
        return .allowed
    }

    /// Query/open/AI-time re-check (not only at index time). Path/ID-level only:
    /// NEVER reads file content — fingerprinting forbidden files is forbidden too.
    public func allowsBook(realPath: String, rootPath: String, bookID: String) -> Bool {
        guard evaluateBookID(bookID) == .allowed else { return false }
        let url = URL(fileURLWithPath: realPath)
        guard evaluate(candidateFileURL: url, rootURL: URL(fileURLWithPath: rootPath)) == .allowed else { return false }
        return true
    }
}

/// Minimal glob matcher supporting '*', '**' and '?' over path strings.
public enum GlobMatcher {
    public static func matches(path: String, pattern: String) -> Bool {
        // Normalize separators for comparison.
        var pat = Substring(pattern)
        var str = Substring(path)
        return match(str, pat)
    }

    private static func match(_ s: Substring, _ p: Substring) -> Bool {
        if p.isEmpty { return s.isEmpty }
        if p.hasPrefix("**") {
            let rest = p.dropFirst(2)
            if rest.isEmpty { return true }
            var remainder = s
            while true {
                if match(remainder, rest) { return true }
                if remainder.isEmpty { return false }
                remainder = remainder.dropFirst()
            }
        }
        guard let pc = p.first else { return s.isEmpty }
        if pc == "*" {
            let rest = p.dropFirst()
            var remainder = s
            while true {
                if match(remainder, rest) { return true }
                // 原 isEmpty 检查 + first 强解包合并为安全解包，
                // 行为逐字等价（空即返回 false）。
                guard let next = remainder.first else { return false }
                if next == "/" { return false } // '*' does not cross '/'
                remainder = remainder.dropFirst()
            }
        }
        guard let sc = s.first else { return false }
        if pc == "?" || pc == sc {
            return match(s.dropFirst(), p.dropFirst())
        }
        return false
    }
}
