#!/bin/sh
# L10n 硬编码回流检查：视图文件中文串必须走 L10n 白名单。
# 白名单外违规 exit 1（供 CI/审查接入）；--json 输出结构化报告。
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$script_dir/l10n-drift-check.py" "$@"
