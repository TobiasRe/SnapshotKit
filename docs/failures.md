# Failures and flaky tests

The **Failures** tab (⌥⌘3) shows every failing snapshot test of the last run — or of a result bundle you
import from CI — with the reference, the image the test produced and the difference, and tells you what kind
of failure it is: a real change, rendering noise, a size change or a flaky test.

![Failures with labels and run history](images/triage.png)

## Where failures come from

| Source | How |
|---|---|
| A run in SnapshotKit | the Run tab, ⌘R, or the ▶ toolbar button. See [Running tests](running.md). |
| A run on a remote Mac | ⌃⌘R. See [Remote runs](remote-runs.md). |
| A verification after re-recording | automatic, when *Verify after re-recording* is on. |
| A CI artifact | **Import Result Bundle…** (⇧⌘O, or the ⤓ button in the Failures header): choose an `.xcresult` downloaded from CI. |

The header says which one you're looking at (*Last run · local · Jan 15, 2027 at 8:00 AM*, *Imported
ci.xcresult*…). Its arrow menu also offers **Open Result Bundle in Xcode** and **Reveal Result Bundle in
Finder**.

SnapshotKit reads the result bundle with `xcresulttool`, exports the failure attachments (reference, failure
and difference images that swift-snapshot-testing attaches) and matches each failure to its reference image
through the path in the failure message — also when the bundle was produced on another machine with other
paths.

A test that fails because *No reference was found on disk* is a new snapshot, not a mismatch; it shows as
such, and recording it is the fix.

## The list

Failing tests are grouped by test target and suite (`AppSnapshotTests › CheckoutViewTests`). Each row has:

- the snapshot's thumbnail and the test name,
- labels: a **verdict** from a flakiness check (*Flaky · 3/5 runs failed*, *Fails every time*), and the
  **diagnosis** of the difference (*Invisible*, *Few pixels*, *Size changed*),
- a **history strip**: one mark per recent run of the test.

The footer sums it up: *2 failing tests in 2 suites · 1 flaky*.

## Reading the history strip

The strip shows the test's last runs (up to twelve), oldest on the left:

| Mark | Meaning |
|---|---|
| green | passed |
| red | failed |
| orange | mixed: repetitions in one run disagreed (a flakiness check) |

A **flaky** test reads as a broken pattern (green, red, green…). A **regression** reads as a clean switch from
green to red. With *Differentiate without color* on (System Settings › Accessibility › Display), the marks
also differ in shape.

## The detail

**Header** — the test, its breadcrumb and the actions:

- **Re-record** (camera, ⇧⌘R): records this test again, then verifies it. The arrow offers **Re-record
  Test** and **Re-record Suite**.
- **···**: Check Flakiness of This Test, Re-record Test / Suite, Open Test in Xcode, Show Reference in
  Library, Reveal Reference in Finder, Open Actual Image, Copy Side-by-Side Image, Copy Test Identifier, Copy
  Failure Message.

**Info row** — the most useful thing known about the failure, in this order:

1. after a flakiness check or with run history: the verdict and the strip, e.g. *Flaky — 4 of 8 passed, 1
   mixed*,
2. otherwise the diagnosis of the difference (*No visible difference (largest ΔE 0.5)…*),
3. otherwise *First failure on record*.

**Message** — the first line of the failure message, and for a flaky test the advice: *Passes sometimes, so
re-recording will not fix it. Look for animations, async loading, dates or random data.*

**Compare** — reference and actual in the [compare view](comparing.md), labelled *Reference* and *Actual ·
<device>*. When the run repeated the test (a flakiness check), a **Repetition** picker shows each attempt.

## What to do with a failure

| Diagnosis | Usually means | Do |
|---|---|---|
| **Visible** change you intended | the UI changed on purpose | Re-record (⇧⌘R), then review on the Changes tab and commit. |
| **Visible** change you didn't intend | a regression | Fix the code; don't re-record. |
| **Invisible** | the reference was recorded on another machine, GPU or OS version | Record where CI runs ([remote runs](remote-runs.md)), or relax `perceptualPrecision` to the suggested value. Re-recording locally just moves the problem to CI. |
| **Few pixels** | anti-aliasing, a blinking caret, a timestamp | Make the view deterministic, or relax `precision` to the suggested value. |
| **Size changed** | another device, scale or layout | Check the test's device and the simulator CI uses. |
| **Flaky** | the test isn't deterministic | Find the animation, async load, date or random value. Re-recording won't help. |

**Re-record All** in the Failures header re-records every failing suite of the last run (⌥⇧⌘R does the same
from anywhere).

## Checking for flakiness

**Check Flakiness** (⌥⌘R, the Failures header, or a test's ··· menu for just that test) runs the failing
tests several times in a row — 5 by default, set under Settings › Flakiness check runs (2–50). Each repetition
runs in a fresh process (`-test-iterations N -test-repetition-relaunch-enabled YES`), so state can't leak
between them.

Each test gets a verdict:

| Verdict | When |
|---|---|
| **Fails every time** | it never passed: a real failure |
| **Flaky** | it passed and failed |
| **Passes** | it never failed this time: it may have been flaky before, or fixed |

The notice sums it up: *5× on local: 1 fail every time, 1 flaky, 0 pass.*

## Run history

Every run SnapshotKit makes or imports is remembered: what ran, where (local, a remote host or an imported
bundle), on which commit and branch, whether the working tree was clean, and every test's outcome per
repetition. That history powers the strips and a second flakiness signal:

> A test that **passed and failed on the same commit** is flaky — no matter which runs or machines did it.

Only runs on a clean working tree count for that signal (otherwise the code may have differed), recording
runs are left out, and imported bundles (which have no commit) don't count either.

History is kept per project in `~/Library/Application Support/SnapshotKit/history/`, the last 100 runs.
`snapkit history` prints it. See [the CLI reference](cli.md#history).

## From the command line

```bash
snapkit failures                          # the last run's failures, diagnosed
snapkit failures --xcresult ci.xcresult   # a CI artifact
snapkit flaky --iterations 10             # check the failing tests 10×
snapkit history 'AppSnapshotTests/CheckoutViewTests/payButton()'
```
