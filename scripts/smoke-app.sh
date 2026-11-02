#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
report="$(mktemp -t windnative-smoke)"
trap 'rm -f "$report"' EXIT
app_dir="$PWD/dist/MyTerm.app"
"$app_dir/Contents/MacOS/MyTerm" --smoke-report "$report"
python3 - "$report" <<'PY'
import json,sys
with open(sys.argv[1]) as file:
    report=json.load(file)
print(json.dumps(report, ensure_ascii=False, indent=2))
if not report.get('passed'):
    raise SystemExit(1)
PY
