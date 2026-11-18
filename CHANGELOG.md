# Changelog

## 0.2.0 — first public preview

Local-first macOS literature search over a personal PDF library:

- Page-level CJK/English full-text search (SQLite FTS5 with LIKE fallback) that returns to the original PDF at the exact page and UTF-16 text range, with fingerprint-checked reopening.
- Atomic updates keep book entries, fingerprints, and searchable pages consistent. Identical PDF copies retain separate entries. An interrupted directory scan preserves the existing index.
- Three-track page semantics: physical page (always known), PDF `/PageLabels` (only when declared), printed page (only from a user-imported CSV page map). Page numbers are never guessed.
- Reading and notes: highlights, page notes, favourites, smart collections, reading history, daily quote. Notes live in the app's own database; the library stays read-only.
- 21 conservative citation formats; BibTeX and annotated-PDF export.
- Optional loopback read-only HTTP API and stdio MCP bridge, both off by default; online metadata lookup behind an allow-list, off by default; AI answers unconfigured by default and gated per request.
- Optional WebDAV downloads preserve existing files when names conflict. Index snapshot uploads are separately enabled and can include paths, extracted text, and notes.
- WidgetKit widget and optional iOS/iPadOS/watchOS companions (simulator-compiled only; device builds need your own team and App Group).
