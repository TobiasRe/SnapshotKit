#!/usr/bin/env bash
# End-to-end check of SnapshotKit against a real Xcode + simulator.
#
# Creates a sample Swift package with one snapshot test and a CI workflow, then:
#   1. records the reference on `develop`
#   2. changes the view on a branch, confirms the test fails and the failing suite is named
#   3. re-records, confirms only the PNG changed (test source restored) and verification passes
#   4. interrupts a re-record with SIGINT/SIGTERM and confirms the record patch is restored
#   5. SIGKILLs a re-record and confirms the next launch restores the leftover patch
#   6. runs the same tests through the remote runner (local-directory transport) and a flakiness check
#
# Usage: scripts/e2e.sh [--keep] [--skip-remote] [--skip-interrupt]
#   E2E_SIMULATOR="<name>" (environment) uses that simulator instead of the newest iPhone, e.g. to leave
#   one that is busy with something else alone.
# Requires: Xcode with an iOS simulator runtime, git, network access for swift-snapshot-testing.
set -euo pipefail

KEEP=0; SKIP_REMOTE=0; SKIP_INTERRUPT=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --skip-remote) SKIP_REMOTE=1 ;;
    --skip-interrupt) SKIP_INTERRUPT=1 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/snapkit-e2e.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
SAMPLE="$WORK/SampleUI"
LOGS="$WORK/logs"
export SNAPSHOTKIT_HOME="$WORK/home"
mkdir -p "$SAMPLE" "$LOGS"

PASS=0; FAILED=0
pass() { PASS=$((PASS + 1)); printf '\033[32mPASS\033[0m %s\n' "$1"; }
failc() { FAILED=$((FAILED + 1)); printf '\033[31mFAIL\033[0m %s\n' "$1"; }
check() { if eval "$2"; then pass "$1"; else failc "$1"; fi; }
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
cleanup() {
  pkill -f "snapkit-e2e" >/dev/null 2>&1 || true
  if [ "$KEEP" = 0 ] && [ "$FAILED" = 0 ]; then rm -rf "$WORK"; else echo "Work directory kept: $WORK"; fi
}
trap cleanup EXIT

step "Build snapkit"
(cd "$ROOT" && swift build --product snapkit 2>&1 | tail -1)
SNAPKIT="$(cd "$ROOT" && swift build --product snapkit --show-bin-path)/snapkit"
sk() { (cd "$SAMPLE" && "$SNAPKIT" "$@"); }

step "Pick the local Xcode and an iPhone simulator for the sample's CI file"
XCODE_VERSION="$(xcodebuild -version | awk 'NR==1 {print $2}')"
read -r SIM_NAME SIM_OS < <(xcrun simctl list devices available -j | E2E_SIMULATOR="${E2E_SIMULATOR:-}" python3 -c '
import json, os as env, sys
data = json.load(sys.stdin)["devices"]
wanted = env.environ.get("E2E_SIMULATOR")
best = None
for runtime, devices in data.items():
    if ".iOS-" not in runtime: continue
    os = runtime.split(".iOS-")[1].replace("-", ".")
    for d in devices:
        if (d["name"] == wanted if wanted else d["name"].startswith("iPhone")) and d.get("isAvailable", True):
            key = tuple(int(x) for x in os.split("."))
            if best is None or key > best[0]: best = (key, d["name"], os)
if not best: sys.exit("no iPhone simulator available")
print(best[1].replace(" ", " "), best[2])
')
SIM_NAME="${SIM_NAME//$' '/ }"
echo "Xcode $XCODE_VERSION · $SIM_NAME · iOS $SIM_OS"

step "Create sample package on develop"
mkdir -p "$SAMPLE/Sources/SampleUI" "$SAMPLE/Tests/SampleUITests" "$SAMPLE/.github/workflows"
cat > "$SAMPLE/Package.swift" <<'EOF'
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SampleUI",
    platforms: [.iOS(.v17)],
    products: [.library(name: "SampleUI", targets: ["SampleUI"])],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
    ],
    targets: [
        .target(name: "SampleUI"),
        .testTarget(
            name: "SampleUITests",
            dependencies: ["SampleUI", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")]
        ),
    ]
)
EOF
cat > "$SAMPLE/Sources/SampleUI/GreetingView.swift" <<'EOF'
import SwiftUI

public struct GreetingView: View {
    public var name: String
    public init(name: String) { self.name = name }

    public var body: some View {
        Text("Hello, \(name)!")
            .font(.title)
            .padding()
            .background(Color.blue.opacity(0.2))
    }
}
EOF
cat > "$SAMPLE/Tests/SampleUITests/GreetingViewTests.swift" <<'EOF'
import SnapshotTesting
import SwiftUI
import Testing
@testable import SampleUI

@MainActor
@Suite(.snapshots(record: .missing))
struct GreetingViewTests {
    @Test func greeting() {
        assertSnapshot(of: GreetingView(name: "World"), as: .image(layout: .fixed(width: 240, height: 120)))
    }
}
EOF
cat > "$SAMPLE/.github/workflows/snapshots.yml" <<EOF
name: Snapshot tests
on:
  pull_request:
    branches: [develop]
env:
  XCODE_VERSION: "$XCODE_VERSION"
  DESTINATION: "platform=iOS Simulator,name=$SIM_NAME,OS=$SIM_OS"
jobs:
  snapshots:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo xcode-select -s "/Applications/Xcode_\${{ env.XCODE_VERSION }}.app"
      - name: Snapshot tests
        run: |
          set -o pipefail
          xcodebuild test \\
            -scheme SampleUI \\
            -destination "\${{ env.DESTINATION }}" | xcbeautify
EOF
printf '.build/\n.swiftpm/\n*.xcresult\n' > "$SAMPLE/.gitignore"
(cd "$SAMPLE" && git init -q -b develop && git config user.email e2e@example.com && git config user.name e2e \
  && git config commit.gpgsign false && git add -A && git commit -qm "Sample package")

step "Configuration is read from the CI workflow"
sk config | tee "$LOGS/config.log"
check "scheme from CI" "grep -q 'scheme *SampleUI.*snapshots.yml' '$LOGS/config.log'"
check "device from CI" "grep -q 'device *$SIM_NAME' '$LOGS/config.log'"
check "Xcode version from CI" "grep -q 'xcode *$XCODE_VERSION' '$LOGS/config.log'"
check "base branch from CI" "grep -q 'baseBranch *develop' '$LOGS/config.log'"

step "Record the reference on develop"
set +e; sk run > "$LOGS/run-record.log" 2>&1; status=$?; set -e
tail -5 "$LOGS/run-record.log"
check "first run records the missing reference" "[ $status -ne 0 ] && grep -q 'No reference was found' '$LOGS/run-record.log'"
PNG="Tests/SampleUITests/__Snapshots__/GreetingViewTests/greeting.1.png"
check "reference PNG written" "[ -f '$SAMPLE/$PNG' ]"
(cd "$SAMPLE" && git add -A && git commit -qm "Record GreetingView reference")
set +e; sk run > "$LOGS/run-pass.log" 2>&1; status=$?; set -e
tail -2 "$LOGS/run-pass.log"
check "run passes against the committed reference" "[ $status -eq 0 ] && grep -q '1 passed' '$LOGS/run-pass.log'"

step "Change the view on a branch"
(cd "$SAMPLE" && git checkout -q -b feature/greeting-color \
  && sed -i '' 's/Color.blue/Color.orange/' Sources/SampleUI/GreetingView.swift \
  && git commit -qam "Make the greeting orange")
set +e; sk run > "$LOGS/run-fail.log" 2>&1; status=$?; set -e
grep -E "FAILING SUITE|Result:" "$LOGS/run-fail.log" || true
check "run fails after the view change" "[ $status -ne 0 ]"
check "failing suite is named" "grep -q 'FAILING SUITE: SampleUITests/GreetingViewTests' '$LOGS/run-fail.log'"
check "failure images exported" "grep -q 'Failure images:' '$LOGS/run-fail.log'"
sk failures > "$LOGS/failures.log" 2>&1 || true
check "failures lists reference path and diff image" "grep -q 'reference: $PNG' '$LOGS/failures.log' && grep -q 'difference: /' '$LOGS/failures.log'"

step "Re-record the failing suite"
TEST_FILE="Tests/SampleUITests/GreetingViewTests.swift"
BEFORE_HASH="$(cd "$SAMPLE" && git hash-object "$PNG")"
set +e; sk rerecord > "$LOGS/rerecord.log" 2>&1; status=$?; set -e
grep -E "snapkit:|Verified|Verification|Recorded" "$LOGS/rerecord.log" || true
check "re-record used the last run's failing suite" "grep -q 'using failing suites from the last run' '$LOGS/rerecord.log'"
check "record mode was enabled only in the suite file" "grep -q 'record mode enabled in $TEST_FILE' '$LOGS/rerecord.log'"
check "re-record verified" "[ $status -eq 0 ] && grep -q 'Verified' '$LOGS/rerecord.log'"
STATUS_LINES="$(cd "$SAMPLE" && git status --porcelain)"
echo "git status: $STATUS_LINES"
check "only the PNG changed" "[ \"\$STATUS_LINES\" = ' M $PNG' ]"
check "PNG content changed" "[ \"\$(cd '$SAMPLE' && git hash-object '$PNG')\" != '$BEFORE_HASH' ]"
check "test source byte-identical to HEAD" "(cd '$SAMPLE' && git diff --quiet HEAD -- '$TEST_FILE')"
check "no patch journal left" "[ ! -f '$SAMPLE/.git/snapshotkit/record-patch.json' ]"
sk changes > "$LOGS/changes.log"
cat "$LOGS/changes.log"
check "change list shows the uncommitted PNG under its suite" "grep -q 'Uncommitted  $PNG' '$LOGS/changes.log' && grep -q '^GreetingViewTests' '$LOGS/changes.log'"
(cd "$SAMPLE" && git commit -qam "Re-record GreetingView")
sk changes > "$LOGS/changes-committed.log"
check "after commit it is listed as committed" "grep -q 'Committed    $PNG' '$LOGS/changes-committed.log'"

step "Library: list snapshots, find orphans, re-record one test"
sk snapshots > "$LOGS/snapshots.log"
cat "$LOGS/snapshots.log"
check "library lists the reference with totals" "grep -q '^$PNG ' '$LOGS/snapshots.log' && grep -q '1 of 1 snapshots · 1 test ·' '$LOGS/snapshots.log'"
ORPHAN="$(dirname "$PNG")/removedTest.1.png"
cp "$SAMPLE/$PNG" "$SAMPLE/$ORPHAN"
sk snapshots --orphans > "$LOGS/orphans.log"
check "a snapshot without a test is orphaned" "grep -q '^$ORPHAN .*orphaned' '$LOGS/orphans.log' && ! grep -q '^$PNG ' '$LOGS/orphans.log'"
rm "$SAMPLE/$ORPHAN"
set +e; sk record greeting > "$LOGS/record-one.log" 2>&1; status=$?; set -e
grep -E "snapkit:|Recorded" "$LOGS/record-one.log" || true
check "record targets the single test" "grep -q 'recording SampleUITests/GreetingViewTests/greeting()' '$LOGS/record-one.log'"
check "record verified" "[ $status -eq 0 ] && grep -q 'Recorded and verified' '$LOGS/record-one.log'"
check "test source byte-identical after record" "(cd '$SAMPLE' && git diff --quiet HEAD -- '$TEST_FILE')"
(cd "$SAMPLE" && git checkout -q -- "$PNG")

if [ "$SKIP_INTERRUPT" = 0 ]; then
  step "Interrupt a re-record (SIGINT) — the patch must be restored"
  (cd "$SAMPLE" && sed -i '' 's/Color.orange/Color.green/' Sources/SampleUI/GreetingView.swift && git commit -qam "Green")
  sk run > "$LOGS/run-fail2.log" 2>&1 || true
  JOURNAL="$SAMPLE/.git/snapshotkit/record-patch.json"
  wait_for_patch() {
    for _ in $(seq 1 600); do
      if [ -f "$JOURNAL" ] && grep -q 'record: .all' "$SAMPLE/$TEST_FILE"; then return 0; fi
      sleep 0.2
    done
    return 1
  }
  (cd "$SAMPLE" && exec -a snapkit-e2e "$SNAPKIT" rerecord --no-verify > "$LOGS/rerecord-int.log" 2>&1) &
  PID=$!
  check "record patch applied while running" "wait_for_patch"
  sleep 3
  kill -INT "$PID"
  wait "$PID" || true
  tail -3 "$LOGS/rerecord-int.log"
  check "SIGINT: test source restored" "(cd '$SAMPLE' && git diff --quiet HEAD -- '$TEST_FILE')"
  check "SIGINT: journal removed" "[ ! -f '$JOURNAL' ]"

  step "Terminate a re-record (SIGTERM) — patch restored and xcodebuild stopped"
  (cd "$SAMPLE" && exec -a snapkit-e2e "$SNAPKIT" rerecord --no-verify > "$LOGS/rerecord-term.log" 2>&1) &
  PID=$!
  check "record patch applied while running" "wait_for_patch"
  sleep 3
  kill -TERM "$PID"
  wait "$PID" || true
  sleep 1
  check "SIGTERM: test source restored" "(cd '$SAMPLE' && git diff --quiet HEAD -- '$TEST_FILE')"
  check "SIGTERM: no xcodebuild left running" "! pgrep -f 'xcodebuild.*-only-testing:SampleUITests/GreetingViewTests' >/dev/null"

  step "Kill a re-record (SIGKILL) — the next launch must restore the leftover patch"
  (cd "$SAMPLE" && exec -a snapkit-e2e "$SNAPKIT" rerecord --no-verify > "$LOGS/rerecord-kill.log" 2>&1) &
  PID=$!
  check "record patch applied while running" "wait_for_patch"
  kill -KILL "$PID"; wait "$PID" 2>/dev/null || true
  pkill -INT -f "xcodebuild.*$WORK" 2>/dev/null || true
  sleep 2
  check "SIGKILL: patch is still on disk (nothing could run)" "grep -q 'record: .all' '$SAMPLE/$TEST_FILE'"
  sk changes > "$LOGS/after-kill.log" 2>&1 || true
  head -3 "$LOGS/after-kill.log"
  check "next launch reports and restores the leftover" "grep -q 'restored leftover record patch' '$LOGS/after-kill.log'"
  check "next launch: test source restored" "(cd '$SAMPLE' && git diff --quiet HEAD -- '$TEST_FILE')"
  (cd "$SAMPLE" && git checkout -q -- . && git clean -qfd Tests)
fi

if [ "$SKIP_REMOTE" = 0 ]; then
  step "Remote runner (local-directory transport) and flakiness check"
  # A fresh view change, so this section does not depend on the interrupt section having run.
  (cd "$SAMPLE" && sed -i '' -E 's/Color\.[a-z]+\.opacity/Color.purple.opacity/' Sources/SampleUI/GreetingView.swift && git commit -qam "Purple")
  printf 'remoteHost: local\nremoteDirectory: %s\n' "$WORK/remote-checkout" > "$SAMPLE/.snapshotkit.yml"
  (cd "$SAMPLE" && git add .snapshotkit.yml && git commit -qm "Remote config")
  set +e; sk run --remote > "$LOGS/remote.log" 2>&1; status=$?; set -e
  grep -E "snapkit:|FAILING|Result:" "$LOGS/remote.log" || true
  check "remote run synced the working tree" "grep -q 'synced working tree to localhost:$WORK/remote-checkout' '$LOGS/remote.log'"
  check "remote run reports the failing suite from remote results" "grep -q 'FAILING SUITE: SampleUITests/GreetingViewTests' '$LOGS/remote.log' && grep -q '\[localhost\]' '$LOGS/remote.log'"
  check "remote copy has no stray files from the local build" "[ ! -d '$WORK/remote-checkout/.git' ]"
  set +e; sk rerecord --remote > "$LOGS/remote-record.log" 2>&1; status=$?; set -e
  grep -E "snapkit:|Downloaded" "$LOGS/remote-record.log" || true
  check "remote re-record downloaded the new reference" "grep -q 'downloaded $PNG' '$LOGS/remote-record.log'"
  check "remote re-record never patched local sources" "(cd '$SAMPLE' && git diff --quiet HEAD -- '$TEST_FILE')"
  check "remote re-record changed only the PNG locally" "[ \"\$(cd '$SAMPLE' && git status --porcelain)\" = ' M $PNG' ]"
  (cd "$SAMPLE" && git checkout -q -- "$PNG")
  set +e; sk flaky --iterations 3 > "$LOGS/flaky.log" 2>&1; set -e
  grep -E "Fails every time|Flaky|Passes" "$LOGS/flaky.log" || true
  check "flakiness check classifies the regression as failing every time" "grep -q 'Fails every time.*0✔ 3✘' '$LOGS/flaky.log'"
  sk history > "$LOGS/history.log"
  check "run history recorded local and remote runs" "grep -q 'localhost' '$LOGS/history.log' && grep -q 'local ' '$LOGS/history.log'"
fi

printf '\n%d passed, %d failed. Logs: %s\n' "$PASS" "$FAILED" "$LOGS"
[ "$FAILED" = 0 ]
