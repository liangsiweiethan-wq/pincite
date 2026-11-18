# Contributing

Short version:

1. Test fixtures must come from `Tests/LiteratureCoreTests/Fixtures/FictionalCorpus.swift` (or be fully invented). Never commit real book data, real file names, credentials, or personal paths.
2. Run `python3 -I Scripts/privacy-gate.py`, `python3 -I Scripts/privacy-gate.py --self-test`, `swift build`, and then `swift test` before committing; all must pass. Run `swift build` before `swift test`; tests that need `.build/debug/literaturesearch-cli` fail directly and explain this requirement. If you add or remove Swift files under `app/`, run `swift Scripts/generate-project.swift` to regenerate the Xcode project. Maintainers may additionally keep a private denylist outside the repository (sha-256 digests only) and point `PRIVACY_DENYLIST` at it; never commit that file.
3. Comments describe what code does and why — not the history of how it got written.

Project rules:

- The library is read-only over the user's PDFs; never write into the library.
- Fail closed and say why: never guess page numbers, never silently approximate stale references.
- New user-facing strings go through `Sources/LiteratureSearchUI/L10n.swift`; `Scripts/l10n-drift-check.sh` must pass.

Before a source release, run the checks from a fresh checkout and verify the generated app targets using Xcode.

```bash
xcodebuild -project app/LiteratureSearch.xcodeproj -scheme LiteratureSearch \
  -configuration Release -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project app/LiteratureSearch.xcodeproj -scheme LiteratureSearchiOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project app/LiteratureSearch.xcodeproj -scheme LiteratureSearchWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
