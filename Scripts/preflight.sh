#!/bin/zsh
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

echo "== 1/6 Privacy Gate =="
python3 -I Scripts/privacy-gate.py
python3 -I Scripts/privacy-gate.py --self-test

echo "== 2/6 Xcode Project Determinism Check =="
BEFORE_SHA=$(shasum -a 256 app/LiteratureSearch.xcodeproj/project.pbxproj | awk '{print $1}')
swift Scripts/generate-project.swift
AFTER_SHA=$(shasum -a 256 app/LiteratureSearch.xcodeproj/project.pbxproj | awk '{print $1}')
if [ "$BEFORE_SHA" != "$AFTER_SHA" ]; then
  echo "error: project.pbxproj drifted after generate-project.swift ($BEFORE_SHA -> $AFTER_SHA)" >&2
  exit 1
fi
echo "project.pbxproj deterministic: $AFTER_SHA"

echo "== 3/6 L10n Drift Check =="
Scripts/l10n-drift-check.sh

echo "== 4/6 Markdown Relative Links Check =="
python3 -I - <<'PY'
import pathlib, re, sys

root = pathlib.Path(".").resolve()
md_files = list(root.glob("*.md")) + list((root / "docs").rglob("*.md"))
link_re = re.compile(r'\[[^\]]*\]\(([^)#\s]+)(?:#[^)\s]*)?\)')
missing = []
for md in sorted(md_files):
    text = md.read_text(encoding="utf-8")
    for m in link_re.finditer(text):
        target = m.group(1)
        if re.match(r'^(https?:|mailto:|literaturesearch:)', target):
            continue
        resolved = (md.parent / target).resolve()
        if not resolved.exists():
            missing.append(f"{md.relative_to(root)} -> {target}")
if missing:
    print("Broken relative markdown links:")
    print("\n".join("  " + x for x in missing))
    sys.exit(1)
print(f"Markdown links verified across {len(md_files)} files: 0 broken")
PY

echo "== 5/6 Build All Targets (warnings-as-errors) =="
swift build --build-tests -Xswiftc -warnings-as-errors

echo "== 6/6 Run Synthetic Test Suite =="
swift test

echo "Preflight passed: 0 violations, 0 warnings, all tests green."
