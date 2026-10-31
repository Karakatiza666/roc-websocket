#!/usr/bin/env bash
# The local and CI checks. Usage: ROC=/path/to/roc scripts/all_tests.sh
set -euo pipefail
ROC="${ROC:-roc}"
cd "$(dirname "$0")/.."

"$ROC" version
"$ROC" fmt --check src examples
"$ROC" check src/main.roc
"$ROC" test src/main.roc
for f in examples/*.roc; do
	"$ROC" check "$f"
	"$ROC" "$f"
done
"$ROC" docs src/main.roc
