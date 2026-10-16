#!/usr/bin/env bash
# Captures the full SnapshotKit window headlessly (off-screen, no activation) for every main view.
#
# Usage: scripts/capture-ui.sh REPO [OUT_DIR] [--with-run]
#   REPO       a git repository with snapshot tests, e.g. the sample kept by `scripts/e2e.sh --keep`
#   OUT_DIR    where PNGs go (default: ./build/ui-captures)
#   --with-run run the snapshot tests from the UI first (needs Xcode + simulator)
#
# Uses a throwaway SNAPSHOTKIT_HOME so your real settings are untouched; the repository's
# last-run state (.git/snapshotkit) is reused if present.
set -euo pipefail

REPO="${1:?usage: capture-ui.sh REPO [OUT_DIR] [--with-run]}"
REPO="$(cd "$REPO" && pwd -P)"
OUT="${2:-build/ui-captures}"
[ "${OUT#--}" != "$OUT" ] && OUT="build/ui-captures"
WITH_RUN=0
for arg in "$@"; do [ "$arg" = "--with-run" ] && WITH_RUN=1; done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$ROOT" && swift build --product SnapshotKit 2>&1 | tail -1)
APP="$(cd "$ROOT" && swift build --show-bin-path)/SnapshotKit"

HOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snapkit-capture.XXXXXX")"
trap 'rm -rf "$HOME_DIR"' EXIT
export SNAPSHOTKIT_HOME="$HOME_DIR/home"
mkdir -p "$SNAPSHOTKIT_HOME" "$HOME_DIR/projects"

# A few extra repositories so the sidebar and quick switcher have something to show.
for name in design-system onboarding-flow payments-ui; do
  dir="$HOME_DIR/projects/$name"
  mkdir -p "$dir/Tests/${name//-/}Tests/__Snapshots__/Suite"
  (cd "$dir" && git init -q && printf 'x' > "Tests/${name//-/}Tests/__Snapshots__/Suite/a.png" && git add -A)
done
cat > "$SNAPSHOTKIT_HOME/settings.json" <<EOF
{
  "scanRoots": ["$HOME_DIR/projects"],
  "discovered": ["$HOME_DIR/projects/design-system", "$HOME_DIR/projects/onboarding-flow", "$HOME_DIR/projects/payments-ui", "$REPO"],
  "pinned": ["$HOME_DIR/projects/design-system"],
  "recents": ["$REPO"]
}
EOF

capture() {
  local name="$1"; shift
  "$APP" --capture "$OUT/$name.png" "$@" 2>&1 | grep '^capture:' || true
}

capture 00-snapshots --project "$REPO" --tab snapshots
capture 00-snapshots-dark --project "$REPO" --tab snapshots --appearance dark
if [ "$WITH_RUN" = 1 ]; then
  capture 01-run-after-run --project "$REPO" --tab run --action run --timeout 900
else
  capture 01-run --project "$REPO" --tab run
fi
capture 02-changes-side-by-side --project "$REPO" --tab changes --compare side-by-side
capture 03-changes-slider --project "$REPO" --tab changes --compare slider
capture 04-changes-difference-zoomed --project "$REPO" --tab changes --compare difference --zoom 4 --pan 200,0
capture 05-failures --project "$REPO" --tab failures --compare side-by-side
capture 06-quick-switcher --project "$REPO" --tab changes --quick-switcher "pay"
rm -f "$SNAPSHOTKIT_HOME/settings.json"
capture 07-welcome

echo "Captures in $OUT:"
ls -1 "$OUT"
