#!/usr/bin/env bash
# Fails when SwiftUI or AppKit report a runtime issue while SnapshotKit shows its screens: the purple
# warnings Xcode shows, such as "Publishing changes from within view updates is not allowed". Tests can't
# see those; they only reach the unified log (subsystem com.apple.runtime-issues).
#
# Usage: scripts/check-runtime-warnings.sh [REPO]
#   REPO  a git repository with snapshot tests to open (default: a sample repository made for the check,
#         with changes against its base branch and a failed last run, so no screen is an empty state)
#
# Opens every section's view, compare mode, the ⌘K palette and the welcome screen in the real app window (off-screen,
# with --capture) while watching the log, using a throwaway SNAPSHOTKIT_HOME so your settings are untouched.
# On failure the log and the captures are kept (under $RUNNER_TEMP on CI).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/snapkit-runtime-check.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
LOG="$WORK/runtime-issues.log"

(cd "$ROOT" && xcodebuild build -project SnapshotKit.xcodeproj -scheme SnapshotKit -derivedDataPath build/DerivedData \
  > "$WORK/build.log" 2>&1) || { cat "$WORK/build.log"; exit 1; }
APP="$ROOT/build/DerivedData/Build/Products/Debug/SnapshotKit.app/Contents/MacOS/SnapshotKit"

# A repository on a feature branch that modified, added and deleted a snapshot, with a last run in which one
# test failed. Its images are references of the app's own snapshot tests.
make_sample() (
  local repo="$1" refs="$ROOT/Tests/SnapshotKitAppTests/__Snapshots__/AppSnapshotTests"
  local snapshots="Tests/SampleAppTests/__Snapshots__"
  mkdir -p "$repo/$snapshots/CardTests" "$repo/$snapshots/ProfileTests" "$WORK/attachments"
  cd "$repo"
  git init -q -b develop
  git config user.email check@example.com && git config user.name check && git config commit.gpgsign false
  printf 'scheme: SampleApp\nbaseBranch: develop\n' > .snapshotkit.yml
  cp "$refs/settings-appearance.light.png" "$snapshots/CardTests/card.1.png"
  cp "$refs/welcome.1.png" "$snapshots/CardTests/legacy.1.png"
  cp "$refs/sidebar-appearance.light.png" "$snapshots/ProfileTests/header.1.png"
  git add -A && git commit -qm "Record references"
  git checkout -qb feature/redesign
  cp "$refs/settings-appearance.dark.png" "$snapshots/CardTests/card.1.png"
  git rm -q "$snapshots/CardTests/legacy.1.png"
  git commit -qam "Redesign the card"
  cp "$refs/sidebar-appearance.dark.png" "$snapshots/ProfileTests/badge.1.png"

  # What `snapkit run` leaves behind: the run's suites and the failure images exported from its result bundle.
  cp "$refs/sidebar-appearance.light.png" "$WORK/attachments/reference.png"
  cp "$refs/sidebar-appearance.dark.png" "$WORK/attachments/failure.png"
  cat > "$WORK/attachments/manifest.json" <<EOF
[{ "testIdentifier": "ProfileTests/header()", "attachments": [
  { "exportedFileName": "reference.png", "suggestedHumanReadableName": "reference_0_1.png" },
  { "exportedFileName": "failure.png", "suggestedHumanReadableName": "failure_0_1.png" }
] }]
EOF
  local profile='{ "bundle": "SampleAppTests", "path": ["ProfileTests"], "failureFiles": [], "tests": [
    { "name": "header()", "identifier": "ProfileTests/header()", "outcome": "failed", "repetitions": ["failed"],
      "failureMessages": ["Snapshot does not match reference.\n\n@−\n\"file://'"$repo/$snapshots"'/ProfileTests/header.1.png\""] }] }'
  local card='{ "bundle": "SampleAppTests", "path": ["CardTests"], "failureFiles": [], "tests": [
    { "name": "card()", "identifier": "CardTests/card()", "outcome": "passed", "repetitions": ["passed"], "failureMessages": [] }] }'
  mkdir -p .git/snapshotkit
  cat > .git/snapshotkit/last-run.json <<EOF
{ "date": "2026-01-01T09:00:00Z", "host": "local", "passed": 1, "failed": 1,
  "attachmentsDirectory": "$WORK/attachments", "failingSuites": [$profile], "suites": [$card, $profile] }
EOF
)

if [ -n "${1:-}" ]; then
  REPO="$(cd "$1" && pwd -P)"
else
  REPO="$WORK/SampleApp"
  make_sample "$REPO"
fi

export SNAPSHOTKIT_HOME="$WORK/home"
mkdir -p "$SNAPSHOTKIT_HOME"
cat > "$SNAPSHOTKIT_HOME/settings.json" <<EOF
{ "discovered": ["$REPO"], "recents": ["$REPO"] }
EOF

# /usr/bin/log: in zsh, `log` is a builtin.
# Everything the app logs, not only runtime issues: seeing its other messages proves the stream works
# here (a CI machine that withholds the log would otherwise pass without having checked anything).
/usr/bin/log stream --style compact --level debug --predicate 'process == "SnapshotKit"' > "$LOG" 2>&1 &
LOG_PID=$!
finish() {
  local status=$?
  kill $LOG_PID 2>/dev/null || true
  if [ $status -eq 0 ]; then rm -rf "$WORK"; else echo "Log and captures kept in $WORK"; fi
}
trap finish EXIT

# The stream attaches asynchronously: open the app until its messages arrive, so the screens below all count.
attached=0
for _ in 1 2 3 4 5; do
  "$APP" --capture "$WORK/warm-up.png" > /dev/null 2>&1 || true
  for _ in $(seq 20); do
    if grep -q "SnapshotKit\[" "$LOG"; then attached=1; break 2; fi
    sleep 0.25
  done
done
if [ "$attached" = 0 ]; then
  echo "✘ The log stream saw nothing from SnapshotKit, so runtime issues couldn't be checked."
  exit 1
fi

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
  show "snapshots-$appearance" --project "$REPO" --section library --appearance "$appearance"
  show "working-copy-$appearance" --project "$REPO" --section working-copy --appearance "$appearance"
  show "changes-$appearance" --project "$REPO" --section comparison --appearance "$appearance"
  show "failures-$appearance" --project "$REPO" --section last-run --appearance "$appearance"
  show "run-$appearance" --project "$REPO" --section run --appearance "$appearance"
done
for mode in side-by-side slider difference toggle; do
  show "compare-$mode" --project "$REPO" --section comparison --compare "$mode"
done
show "palette" --project "$REPO" --section library --quick-switcher ""
rm -f "$SNAPSHOTKIT_HOME/settings.json"
show "welcome"

sleep 2 # let the last messages reach the stream
kill $LOG_PID 2>/dev/null || true
wait $LOG_PID 2>/dev/null || true

seen="$(grep -c "SnapshotKit\[" "$LOG" || true)"
issues="$(grep -F "[com.apple.runtime-issues" "$LOG" || true)"
if [ -n "$issues" ]; then
  count="$(printf '%s\n' "$issues" | wc -l | tr -d ' ')"
  echo
  echo "✘ $count runtime issue(s) while showing $screens screens:"
  printf '%s\n' "$issues" | sed -E 's/^.*\[com\.apple\.runtime-issues:([^]]*)\] /  [\1] /' | sort | uniq -c
  exit 1
fi
echo
echo "✔ No runtime issues in $screens screens ($seen log messages from the app checked)."
