# Changelog

All notable changes to **PinCite** (formerly *LiteratureSearch*) will be documented in this file.

## [0.3.0] - 2026-11-19

### Added
- Rebranded user-facing product identity to **PinCite (页锚)** with unified `0.3.0 (3)` versioning across the macOS app, iOS/watchOS companions, Widgets, and Share Extension (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` managed via `Scripts/generate-project.swift`).
- Editorial SVG hero banner (`docs/assets/hero.svg`), launch promotion copy (`docs/LAUNCH-KIT.md`), community templates, `CODE_OF_CONDUCT.md`, `Scripts/preflight.sh`, and reproducible ad-hoc DMG packager `Scripts/package-release.sh`.
- Automated GitHub Release workflow (`.github/workflows/release.yml`) and expanded CI checks across macOS Release, iOS Simulator, watchOS Simulator, and offline CLI smoke tests.

### Fixed
- **TTSSpeaker**: Retained `SpeechDelegate` strongly so `AVSpeechSynthesizer` finish/cancel callbacks fire reliably and `speaking` resets properly.
- **OCR Subprocess Drivers**: Replaced `waitUntilExit()` and `DispatchSemaphore.wait` inside `async` functions in `OcrDrivers.swift` with `withCheckedThrowingContinuation`, `terminationHandler`, and lock-protected timeout state—eliminating the 5-second unconditional post-exit stall, cooperative thread pool blocking, and timeout race condition.
- **Swift 6 Concurrency & Zero Warnings**: Resolved all 341 compiler warnings across all production and test targets (35 `async` `NSLock` sites in `RefreshEngine`, `Sendable` conformances in `AIAssistantService`, `@Sendable` closure captures in `AppState`, `SnapshotWindowController`, `RefreshConsoleStore`, and test helpers).
- **Hygiene & Docs**: Removed stale empty directory `app/iOS/iOS/`, repaired truncated comments, deduplicated `Scripts/privacy-allowlist.txt`, and updated `docs/SCHEMA.md` to accurately document `schema_version = 13`, the `fulltext.db` split, and migrations through V14.

### Performance
- **Cold-Open Fast Path**: Cached `FTS5Probe.probeOrDefault()` in-process so opening an `IndexStore` no longer spins up a disposable `:memory:` SQLite instance and three FTS5 virtual tables on every open.
- **Redundant Write Elimination**: Skipped redundant `meta` write transactions for `sqlite_version`, `schema_version`, and `index_schema_version` when the stored values already match.

## [0.2.0] - 2026-11-18 — First Public Source Preview

Local-first macOS literature search over a personal PDF library:

- Page-level CJK/English full-text search (SQLite FTS5 with LIKE fallback) that returns to the original PDF at the exact page and UTF-16 text range, with fingerprint-checked reopening.
- Atomic updates keep book entries, fingerprints, and searchable pages consistent. Identical PDF copies retain separate entries. An interrupted directory scan preserves the existing index.
- Three-track page semantics: physical page (always known), PDF `/PageLabels` (only when declared), printed page (only from a user-imported CSV page map). Page numbers are never guessed.
- Reading and notes: highlights, page notes, favourites, smart collections, reading history, daily quote. Notes live in the app's own database; the library stays read-only.
- 21 conservative citation formats; BibTeX and annotated-PDF export.
- Optional loopback read-only HTTP API and stdio MCP bridge, both off by default; online metadata lookup behind an allow-list, off by default; AI answers unconfigured by default and gated per request.
- Optional WebDAV downloads preserve existing files when names conflict. Index snapshot uploads are separately enabled and can include paths, extracted text, and notes.
- WidgetKit widget and optional iOS/iPadOS/watchOS companions (simulator-compiled only; device builds need your own team and App Group).
