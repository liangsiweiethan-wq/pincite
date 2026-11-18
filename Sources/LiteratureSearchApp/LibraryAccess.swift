import Foundation
import AppKit
import PDFKit
import LiteratureCore

/// Security-scoped folder access for every explicitly selected root.
/// A root exists only if the user picked it in an open panel; the security-
/// scoped bookmark is persisted per role, and access is started ONLY around
/// explicit work (index / OCR pair import / opening a hit). The app never
/// reads a directory the user has not selected — no defaults, no auto-restore
/// of content, no scanning on launch.
final class LibraryAccess {
    enum Role: String {
        case library        // library root: indexing + native open
        case originalRoot   // originals root for OCR pairs
        case ocrRoot        // OCR derivative root for OCR pairs
    }

    static func bookmarkKey(for role: Role) -> String { "literature.root.bookmark.\(role.rawValue)" }

    private(set) var urls: [Role: URL] = [:]
    private var accessing: Set<Role> = []

    /// Explicit user action: pick a root and store a security-scoped bookmark.
    func pickFolder(role: Role, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        urls[role] = url
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey(for: role))
        }
        return url
    }

    /// Restores a root from its stored bookmark. Without a stored bookmark
    /// there is NO root: nothing is invented, nothing is read.
    func restore(_ role: Role) -> URL? {
        if let url = urls[role] { return url }
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey(for: role)) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        urls[role] = url
        return url
    }

    /// Starts security-scoped access for the given roles; returns the roots
    /// that are available (missing bookmark = no access, no fallback).
    @discardableResult
    func startAccess(_ roles: [Role]) -> [Role: URL] {
        var started: [Role: URL] = [:]
        for role in roles {
            guard let url = restore(role) else { continue }
            if !accessing.contains(role), url.startAccessingSecurityScopedResource() {
                accessing.insert(role)
            }
            started[role] = url
        }
        return started
    }

    func stopAllAccess() {
        for role in accessing {
            urls[role]?.stopAccessingSecurityScopedResource()
        }
        accessing.removeAll()
    }

    // Single-root conveniences (library root; earlier API kept stable).
    func pickFolder() -> URL? { pickFolder(role: .library, prompt: "选择文献目录") }
    func restoreRoot() -> URL? { restore(.library) }
    @discardableResult
    func startAccess() -> URL? { startAccess([.library])[.library] }
    func stopAccess() { stopAllAccess() }
}

/// Read-only open of a single PDF for display, plus its content fingerprint.
enum PDFFileOpener {
    static func openForDisplay(_ url: URL) -> (document: PDFDocument, fingerprint: String?)? {
        guard let document = PDFDocument(url: url) else { return nil }
        let fingerprint = try? Fingerprint.sha256Hex(ofFileAt: url)
        return (document: document, fingerprint: fingerprint)
    }
}
