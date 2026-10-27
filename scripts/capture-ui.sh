#!/usr/bin/env bash
# Captures the full SnapshotKit window headlessly (off-screen, no activation) for every main view.
#
# Usage: scripts/capture-ui.sh REPO [OUT_DIR] [--with-run]
#   REPO       a git repository with snapshot tests, e.g. the sample kept by `scripts/e2e.sh --keep`
#   OUT_DIR    where PNGs go (default: ./build/ui-captures)
#   --with-run run the snapshot tests from the UI first (needs Xcode + simulator)
#   APPEARANCE=dark (environment) captures every view in dark mode
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
HOME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snapkit-capture.XXXXXX")"
trap 'rm -rf "$HOME_DIR"' EXIT
(cd "$ROOT" && xcodebuild build -project SnapshotKit.xcodeproj -scheme SnapshotKit -derivedDataPath build/DerivedData \
  > "$HOME_DIR/build.log" 2>&1) || { cat "$HOME_DIR/build.log"; exit 1; }
APP="$ROOT/build/DerivedData/Build/Products/Debug/SnapshotKit.app/Contents/MacOS/SnapshotKit"

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
  # Only the app's progress lines; with pipefail, a failing app still stops the script.
  # In English whatever the Mac's language, so dates and numbers read like the docs around them.
  "$APP" --capture "$OUT/$name.png" "$@" ${APPEARANCE:+--appearance "$APPEARANCE"} \
    -AppleLanguages "(en)" -AppleLocale en_US 2>&1 | { grep '^capture:' || true; }
}

capture 00-snapshots --project "$REPO" --section library
capture 00-snapshots-dark --project "$REPO" --section library --appearance dark
if [ "$WITH_RUN" = 1 ]; then
  capture 01-run-after-run --project "$REPO" --section run --action run --timeout 900
else
  capture 01-run --project "$REPO" --section run
fi
capture 02-working-copy --project "$REPO" --section working-copy
capture 02-changes-side-by-side --project "$REPO" --section comparison --compare side-by-side
capture 03-changes-slider --project "$REPO" --section comparison --compare slider
capture 04-changes-difference-zoomed --project "$REPO" --section comparison --compare difference --zoom 4 --pan 200,0
capture 05-failures --project "$REPO" --section last-run --compare side-by-side
capture 06-quick-switcher --project "$REPO" --section comparison --quick-switcher "pay"
rm -f "$SNAPSHOTKIT_HOME/settings.json"
capture 07-welcome

echo "Captures in $OUT:"
ls -1 "$OUT"
