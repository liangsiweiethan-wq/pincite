#!/usr/bin/env python3
"""L10n 硬编码回流检查。

扫描 Sources/LiteratureSearchApp/ 视图文件中的中文字符串字面量；
合规标准 = 该行含 L10n 引用，或落在白名单（legacy 豁免，逐条带理由）。
输出逐文件违规数；白名单外违规 exit 1。

用法: Scripts/l10n-drift-check.sh [--json]
"""
import re
import sys
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "Sources" / "LiteratureSearchApp"

CJK = re.compile(r'[一-鿿]')
STRING_LIT = re.compile(r'"((?:[^"\\]|\\.)*)"')

# 非视图状态/入口文件：不含 SwiftUI 视图文案，不在扫描范围
EXCLUDED_FILES = {
    "AppState.swift",          # 状态层（消息文案属状态逻辑；迁移另行立项）
    "LibraryAccess.swift",     # 文件访问层（NSOpenPanel prompt 属系统对话框）
    "LiteratureSearchAppMain.swift",  # @main 入口
}

# legacy 白名单：file -> [(行匹配子串, 理由)]。逐条登记，禁止泛化。
WHITELIST = {
    "ZeroHitView.swift": [
        ('line.contains("无文字层")', "与 HitRouter 核心输出对拍的判别串（核心层文案，非 UI 文案）"),
        ('line.contains("无法评估")', "与 HitRouter 核心输出对拍的判别串（核心层文案，非 UI 文案）"),
    ],
    "SearchResultListView.swift": [
        ("（点开书目查看该书全部命中）", "遗留混排串；含 L10n 插值，整体迁移待文案审"),
    ],
    "CoverageView.swift": [
        ('" · 已取消"', "覆盖页运行行尾缀；遗留项"),
    ],
    "LibrarySettingsView.swift": [
    ],
    "BookDetailView.swift": [
    ],
    "AIPreviewPanel.swift": [
        ('"服务: \\(', "预览卡信息行 legacy 拼装"),
        ('"引用已接受: \\(bookID) 物理页 \\(page)"', "守卫回执串；含内部 ID 属登记豁免出处行的同类，迁移待审查"),
        ('"引用已拒绝: \\(bookID) 页 \\(page) — \\(reason)"', "守卫回执串；迁移待审查"),
    ],
    "OnboardingStepsView.swift": [
    ],
    "RootView.swift": [
    ],
    "HistoryView.swift": [
    ],
    "SearchView.swift": [
    ],
    "SearchDebugPanelView.swift": [
    ],
    "PDFDetailView.swift": [
    ],
    "DetailChromeView.swift": [
    ],
    "ReadingChrome.swift": [
    ],
}


def cjk_literals_in_line(text: str):
    """返回该行所有含 CJK 的字符串字面量内容（排除注释行）。"""
    stripped = text.strip()
    if stripped.startswith("//"):
        return []
    out = []
    for m in STRING_LIT.finditer(text):
        if CJK.search(m.group(1)):
            out.append(m.group(1))
    return out


def main() -> int:
    as_json = "--json" in sys.argv
    report = {}
    violations_outside = []
    stale_whitelist = []
    total = 0

    scanned = [p for p in sorted(APP.glob("*.swift"))
               if p.name not in EXCLUDED_FILES]
    for path in scanned:
        name = path.name
        lines = path.read_text(encoding="utf-8").splitlines()
        file_whitelist = WHITELIST.get(name, [])
        matched_keys = set()
        hits = []
        for lineno, raw in enumerate(lines, 1):
            lits = cjk_literals_in_line(raw)
            if not lits:
                continue
            for key, _ in file_whitelist:
                if key in raw:
                    matched_keys.add(key)
            # 行内每个 CJK 字面量独立判责：该行命中任一白名单键即整行豁免
            allowed = any(key in raw for key, _ in file_whitelist)
            entry = {"line": lineno,
                     "literals": [l[:80] for l in lits],
                     "whitelisted": allowed}
            hits.append(entry)
            total += len(lits)
            if not allowed:
                violations_outside.append(f"{name}:{lineno}: {raw.strip()[:100]}")
        # 白名单漂移检查：表内键在本文件中无任何行命中 → 失效登记
        for key, reason in file_whitelist:
            if not any(key in raw for raw in lines):
                stale_whitelist.append(f"{name}: [{key}]（{reason}）")
        if hits:
            report[name] = hits

    out = {
        "files_scanned": len(scanned),
        "total_cjk_string_literals": total,
        "violations_outside_whitelist": len(violations_outside),
        "stale_whitelist_entries": len(stale_whitelist),
        "per_file": {
            k: {"lines": len(v),
                "literals": sum(len(e["literals"]) for e in v),
                "whitelisted_lines": sum(1 for e in v if e["whitelisted"])}
            for k, v in report.items()
        },
    }

    if as_json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
    else:
        print(f"files scanned : {out['files_scanned']}")
        print(f"CJK string literals total : {total}")
        for k, v in out["per_file"].items():
            bad = v["lines"] - v["whitelisted_lines"]
            print(f"  {k}: {v['lines']} 行 / {v['literals']} 字面量"
                  f"（豁免 {v['whitelisted_lines']}，违规 {bad}）")
        print(f"violations outside whitelist : {len(violations_outside)}")
        for v in violations_outside:
            print(f"  {v}")
        print(f"stale whitelist entries : {len(stale_whitelist)}")
        for s in stale_whitelist:
            print(f"  {s}")

    return 1 if (violations_outside or stale_whitelist) else 0


if __name__ == "__main__":
    sys.exit(main())
