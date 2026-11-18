import Foundation

// MARK: - Bibliographic metadata sidecar import (read-only w.r.t. originals)
//
// The user explicitly selects a sidecar CSV/JSON that maps indexed PDFs to
// bibliographic metadata (title/author/version/language). Import writes ONLY
// to the index; original files are never read for this (path matching only)
// and never modified. Unknown stays unknown: absent fields stay nil; records
// that match no indexed book are reported and skipped — never guessed.

public struct MetadataRecord: Equatable {
    public var file: String          // file name or root-relative path of an indexed PDF
    public var title: String?
    public var author: String?
    public var version: String?
    public var language: String?

    public init(file: String, title: String?, author: String?, version: String?, language: String?) {
        self.file = file
        self.title = title
        self.author = author
        self.version = version
        self.language = language
    }
}

public struct MetadataImportReport: Equatable {
    public struct Skipped: Equatable {
        public var file: String
        public var reason: String
    }
    public var applied: Int = 0
    public var skipped: [Skipped] = []
    public var totalRecords: Int = 0
}

public enum MetadataImportError: Error, CustomStringConvertible {
    case badFormat(String)
    // 修（开发环境，技术债修复说明）：同
    // AIAssistantError——自引用 description 对带关联值枚举是栈溢出炸弹。
    public var description: String {
        switch self {
        case .badFormat(let detail): return "badFormat(\(detail))"
        }
    }
}

public enum MetadataImporter {
    /// Applies records against the index. Matching is by exact file_name first,
    /// then root-relative path. Only non-nil fields overwrite (nil = keep).
    public static func apply(_ records: [MetadataRecord], store: IndexStore) -> MetadataImportReport {
        var report = MetadataImportReport()
        report.totalRecords = records.count
        let books = (try? store.allBooks()) ?? []
        for record in records {
            let needle = record.file.trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty else {
                report.skipped.append(.init(file: record.file, reason: "empty file field"))
                continue
            }
            guard let book = books.first(where: { $0.fileName == needle })
                ?? books.first(where: { $0.relPath == needle })
                ?? books.first(where: { $0.relPath == needle.replacingOccurrences(of: "\\", with: "/") }) else {
                report.skipped.append(.init(file: needle, reason: "no matching indexed book (not guessed)"))
                continue
            }
            do {
                let ok = try store.updateMetadata(bookID: book.id, title: record.title, author: record.author,
                                                  version: record.version, language: record.language,
                                                  source: "sidecar")
                if ok { report.applied += 1 } else {
                    report.skipped.append(.init(file: needle, reason: "book row not updated"))
                }
            } catch {
                report.skipped.append(.init(file: needle, reason: String(describing: error)))
            }
        }
        return report
    }

    // MARK: JSON sidecar
    // {"books": [{"file": "a.pdf", "title": "...", "author": "...", "version": "...", "language": "zh"}]}

    public static func parseJSON(_ data: Data) throws -> [MetadataRecord] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = root["books"] as? [[String: Any]] else {
            throw MetadataImportError.badFormat("JSON sidecar must be {\"books\": [{\"file\": ..., ...}]}")
        }
        var records: [MetadataRecord] = []
        for (i, item) in array.enumerated() {
            guard let file = item["file"] as? String else {
                throw MetadataImportError.badFormat("record #\(i) missing \"file\"")
            }
            func str(_ key: String) -> String? {
                (item[key] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            records.append(MetadataRecord(file: file, title: str("title"), author: str("author"),
                                          version: str("version"), language: str("language")))
        }
        return records
    }

    // MARK: CSV sidecar

    public static func parseCSV(_ data: Data) throws -> [MetadataRecord] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw MetadataImportError.badFormat("CSV must be UTF-8")
        }
        let rows = parseCSVRows(text)
        guard let header = rows.first else { throw MetadataImportError.badFormat("CSV is empty") }
        let normalizedHeader = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let required = ["file", "title", "author", "version", "language"]
        for column in required where !normalizedHeader.contains(column) {
            throw MetadataImportError.badFormat("CSV header missing column: \(column)")
        }
        let indexes = Dictionary(uniqueKeysWithValues: required.map { ($0, normalizedHeader.firstIndex(of: $0)!) })

        var records: [MetadataRecord] = []
        for (rowIndex, row) in rows.dropFirst().enumerated() {
            func cell(_ name: String) -> String? {
                let idx = indexes[name]!
                guard idx < row.count else { return nil }
                let value = row[idx].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            guard let file = cell("file") else {
                throw MetadataImportError.badFormat("CSV row #\(rowIndex + 1) missing file value")
            }
            records.append(MetadataRecord(file: file, title: cell("title"), author: cell("author"),
                                          version: cell("version"), language: cell("language")))
        }
        return records
    }

    static func parseCSVRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil

        func endField() { row.append(field); field = "" }
        func endRow() { endField(); if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }; row = [] }

        while true {
            let ch = pending ?? iterator.next()
            pending = nil
            guard let ch else { break }
            if inQuotes {
                if ch == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\""); continue }
                        pending = next; inQuotes = false; continue
                    } else {
                        inQuotes = false; continue
                    }
                }
                field.append(ch)
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",": endField()
                case "\r": continue
                case "\n": endRow()
                default: field.append(ch)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
