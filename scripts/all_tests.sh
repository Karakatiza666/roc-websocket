#!/usr/bin/env bash
# The local and CI checks. Usage: ROC=/path/to/roc scripts/all_tests.sh
set -euo pipefail
ROC="${ROC:-roc}"
cd "$(dirname "$0")/.."
# Keep the roc cache inside the repository.
export ROC_CACHE_DIR="${ROC_CACHE_DIR:-$PWD/.cache/roc}"
mkdir -p "$ROC_CACHE_DIR"

"$ROC" version
"$ROC" fmt --check src examples tests
"$ROC" check src/main.roc
# The expects next to the code: RFC 6455, RFC 4648 and SHA-1 vectors, the protocol state machine.
"$ROC" test src/main.roc
# The client over a scripted link, through the public API of the package.
for f in examples/*.roc tests/*.roc; do
	"$ROC" check "$f"
	"$ROC" "$f"
done
"$ROC" docs src/main.roc --output="$ROC_CACHE_DIR/docs" >/dev/null
