#!/usr/bin/env bash
# Fails when SwiftUI or AppKit report a runtime issue while SnapshotKit shows its screens: the purple
# warnings Xcode shows, such as "Publishing changes from within view updates is not allowed". Tests can't
# see those; they only reach the unified log (subsystem com.apple.runtime-issues).
#
# Usage: scripts/check-runtime-warnings.sh [REPO]
#   REPO  a git repository with snapshot tests to open (default: this repository, which has its own)
#
# Opens every tab, compare mode, the ⌘K palette and the welcome screen in the real app window (off-screen,
# with --capture) while watching the log, using a throwaway SNAPSHOTKIT_HOME so your settings are untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "${1:-$ROOT}" && pwd -P)"

(cd "$ROOT" && swift build --product SnapshotKit 2>&1 | tail -1)
APP="$(cd "$ROOT" && swift build --show-bin-path)/SnapshotKit"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/snapkit-runtime-check.XXXXXX")"
LOG="$WORK/runtime-issues.log"
export SNAPSHOTKIT_HOME="$WORK/home"
mkdir -p "$SNAPSHOTKIT_HOME"
cat > "$SNAPSHOTKIT_HOME/settings.json" <<EOF
{ "discovered": ["$REPO"], "recents": ["$REPO"] }
EOF

# /usr/bin/log: in zsh, `log` is a builtin.
/usr/bin/log stream --style compact --level debug \
  --predicate 'subsystem == "com.apple.runtime-issues" AND process == "SnapshotKit"' > "$LOG" 2>&1 &
LOG_PID=$!
trap 'kill $LOG_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT
sleep 2 # the stream attaches asynchronously

screens=0
show() {
  local name="$1"; shift
  screens=$((screens + 1))
  if ! "$APP" --capture "$WORK/$name.png" "$@" > "$WORK/$name.out" 2>&1; then
    echo "  ✘ $name: the app failed ($(tail -1 "$WORK/$name.out"))"
    exit 1
  fi
  echo "  ✔ $name"
}

echo "Showing SnapshotKit's screens for $REPO:"
for appearance in light dark; do
  show "snapshots-$appearance" --project "$REPO" --tab snapshots --appearance "$appearance"
  show "changes-$appearance" --project "$REPO" --tab changes --appearance "$appearance"
  show "failures-$appearance" --project "$REPO" --tab failures --appearance "$appearance"
  show "run-$appearance" --project "$REPO" --tab run --appearance "$appearance"
done
for mode in side-by-side slider difference toggle; do
  show "compare-$mode" --project "$REPO" --tab changes --compare "$mode"
done
show "palette" --project "$REPO" --tab snapshots --quick-switcher ""
rm -f "$SNAPSHOTKIT_HOME/settings.json"
show "welcome"

sleep 2 # let the last messages reach the stream
kill $LOG_PID 2>/dev/null || true
wait $LOG_PID 2>/dev/null || true

issues="$(grep -F "runtime-issues" "$LOG" | grep -v '^Filtering' || true)"
if [ -n "$issues" ]; then
  count="$(printf '%s\n' "$issues" | wc -l | tr -d ' ')"
  echo
  echo "✘ $count runtime issue(s) while showing $screens screens:"
  printf '%s\n' "$issues" | sed -E 's/^.*\[com\.apple\.runtime-issues:([^]]*)\] /  [\1] /' | sort | uniq -c
  exit 1
fi
echo
echo "✔ No runtime issues in $screens screens."
