# Configuration

Most projects need no configuration: SnapshotKit reads how your CI runs the snapshot tests and does the same.
This page explains what it reads, in which order, how to override it with `.snapshotkit.yml`, and how Xcode,
the simulator and the base branch are chosen.

`snapkit config` (or the Run tab’s configuration panel) shows the result, with the source of every value:

```
$ snapkit config
Repository: /Users/me/Developer/Shop
CI files:   .github/workflows/snapshots.yml
Override:   .snapshotkit.yml
  xcode          16.2  (.github/workflows/snapshots.yml)
  device         iPhone 16 Pro  (.snapshotkit.yml)
  os             18.2  (.snapshotkit.yml)
  scheme         Shop  (.github/workflows/snapshots.yml)
  workspace      —
  project        —
  testPlan       —
  onlyTesting    —
  baseBranch     develop  (.github/workflows/snapshots.yml)
  workingDir     —
  remoteHost     —
  modules        ShopTests
snapkit: Xcode 16.2 · iPhone 16 Pro iOS 18.2
```

The last line checks that this Xcode and simulator exist; `snapkit config` exits with status 2 when they
don’t, and with 1 when the configuration can’t be read.

## Order of precedence

From lowest to highest — a later source overrides an earlier one, field by field:

1. **CI variables** — values found in variables your CI defines (`SCHEME: Shop`, `SIMULATOR: iPhone 16 Pro`).
2. **The CI command line** — the arguments of the `xcodebuild` call your CI makes.
3. **`.snapshotkit.yml`** — every key it sets.
4. **Per-project settings in the app** (and `snapkit` options): the base branch and remote host you typed on
   the Run tab, and the test target you picked. These are personal and not committed.

Anything still unset falls back to defaults: the base branch from git, the only workspace or project in the
repository, the scheme from `xcodebuild -list`.

## What SnapshotKit reads from CI

### Files

1. `.gitlab-ci.yml`, and the **local** files it includes (`include: ci/ios.yml`, `- local: ci/ios.yml`). Includes of
   included files aren’t followed.
2. `.github/workflows/*.yml` and `*.yaml`, alphabetically.
3. Shell scripts that those files call (`./ci/snapshots.sh`, `scripts/test.sh`) — only when the files above
   contain no `xcodebuild` call themselves. One level deep: scripts called by scripts aren’t read.

With none of these, `.snapshotkit.yml` is the only configuration.

### The test command

SnapshotKit looks for `xcodebuild` invocations. Line continuations (`\`) and YAML-folded lines are joined; the
command ends at the first `|`, `;`, `>`, `<`, `&&`, comment or the `)` of the subshell it runs in. When there
are several, it picks the one most likely to run snapshot tests:

- `test` / `test-without-building` actions score highest, `build-for-testing` a little,
- a command that mentions “snapshot”, or follows a line that does, scores more.

From the chosen command it takes `-scheme`, `-workspace`, `-project`, `-testPlan`, `-destination` (`name=`,
`OS=`, `platform=`), every `-only-testing` and `-skip-testing`, and the working directory: GitHub Actions’
`working-directory` (the step’s, else `defaults.run` of the job or workflow), followed by every `cd`, `pushd`
and `popd` before the command in the same shell (also in GitLab’s `before_script`; for a command in a `( … )`
subshell, those before it in there too). For a command in a shell function, that is those before the function
is first called, then those in its body before the command. GitLab’s `before_script` is the job’s own — also one
merged in from an anchor (`<<: *ios`) — else that of the jobs it `extends:` (in any file read; of several, the
last that has one), else that of `default:`.

Only `xcodebuild` is understood. Swift packages tested with `swift test` in CI: set `scheme:` (the
`<Package>-Package` scheme) and `device:` in `.snapshotkit.yml`, or let SnapshotKit find the package scheme.

### Variables

Variables defined anywhere in those files are collected (`KEY: value`, `KEY=value`, `export KEY=value`, `- KEY=
value`; the first definition wins; for a matrix list the first value) and expanded in the command:
`$VAR`, `${VAR}`, and GitHub’s `${{ env.VAR }}`, `${{ vars.VAR }}`, `${{ matrix.VAR }}`, `${{ inputs.VAR }}`.
A value that still contains `$` after expansion is treated as unknown.

As in GitLab, a job’s own `variables:` override the top-level ones: those it defines, and those of the jobs it
`extends:` (the last listed over earlier ones), in any of those files. A command in a job sees the job’s
values. When the command is out of sight in a remote template, the snapshot job’s values count: the first job
named for snapshots, else the first that `extends:` a template that is (`.snapshot-test-job-template`).

When the command doesn’t name something, a variable can:

| Field | Variables used |
|---|---|
| scheme | a name with `SNAPSHOT` and `SCHEME`, else `TEST` and `SCHEME`, else `SCHEME` |
| workspace / project | a value ending in `.xcworkspace` / `.xcodeproj` |
| testPlan | a name containing `TEST_PLAN` or `TESTPLAN` |
| device | a name containing `SIMULATOR`, `DEVICE` or `DESTINATION`, with a value like `iPhone 16 Pro`, `iPhone 16 Pro (18.2)`, `iPhone 16 Pro,OS=18.2` or a full destination |
| os | a name containing `OS_VERSION`, `SIMULATOR_OS` or `RUNTIME` with a numeric value |

The Run tab names the variable as the source (*.gitlab-ci.yml · SIMULATOR*), and the job when it’s the job’s
(*.gitlab-ci.yml · snapshotTest · SCHEME*).

### The Xcode version

Searched in the file with the test command first:

1. `xcode-version: 16.2` (e.g. `maxim-lobanov/setup-xcode`),
2. an Xcode path such as `/Applications/Xcode_16.2.app` or `Xcode-16.2.app`,
3. a variable like `XCODE_VERSION: 16.2`,
4. `xcodes select 16.2`, `xcversion select 16.2`,
5. a CI image tag like `macos-xcode:16.2`.

Otherwise a `DEVELOPER_DIR=` or `xcode-select -s` path is used as the Xcode to run.

### Shared CI templates

When the test job comes from a template SnapshotKit can’t read (GitLab `project:`, `remote:`, `template:` or
`component:` includes), it takes what it can from your variables and says so: *The test job comes from …,
which SnapshotKit can’t read. Settings were taken from CI variables; set anything missing in
`.snapshotkit.yml`.*

## `.snapshotkit.yml`

Put a `.snapshotkit.yml` at the repository root to set or override anything. Commit it to share the setup.

```yaml
# .snapshotkit.yml
xcode: "16.2"
device: iPhone 16 Pro
os: "18.2"
scheme: Shop
workspace: Shop.xcworkspace
testPlan: Snapshots
onlyTesting: [ShopSnapshotTests]
baseBranch: develop
remoteHost: ci-mac
```

### Keys

| Key | Also accepted | Type | Meaning | Example |
|---|---|---|---|---|
| `xcode` | `xcodeVersion` | string | Xcode version to use | `"16.2"` |
| `developerDir` | `xcodePath` | path | a specific Xcode (`.app` or `.app/Contents/Developer`) | `/Applications/Xcode-16.2.app` |
| `platform` | | string | simulator platform; default `iOS Simulator` | `iOS Simulator` |
| `device` | `simulator` | string | simulator name | `iPhone 16 Pro` |
| `os` | `osVersion`, `iosVersion` | string | runtime version, or `latest` | `"18.2"` |
| `scheme` | | string | `-scheme` | `Shop` |
| `workspace` | | path | `-workspace` | `Shop.xcworkspace` |
| `project` | | path | `-project` | `Shop.xcodeproj` |
| `testPlan` | | string | `-testPlan` | `Snapshots` |
| `onlyTesting` | | list | `-only-testing` identifiers | `[ShopSnapshotTests]` |
| `skipTesting` | | list | `-skip-testing` identifiers | `[ShopSnapshotTests/SlowTests]` |
| `baseBranch` | | string | the branch the Changes tab compares with | `develop` |
| `workingDirectory` | | path | where to run `xcodebuild`, relative to the root | `Modules/Feature` |
| `extraArguments` | | string or list | more `xcodebuild` arguments; a string is split like a shell would | `-configuration Debug` |
| `remoteHost` | `remote` | string | the Mac for [remote runs](remote-runs.md) | `ci-mac` |
| `remoteDirectory` | | path | the working copy on the remote Mac (`~/` allowed) | `~/snapshots/shop` |

Quote version numbers (`"16.2"`), or YAML-minded readers may take them for numbers. A list key that’s present
but empty (`onlyTesting:`) clears what CI set.

### Format

`.snapshotkit.yml` is a flat file: `key: value` lines, inline lists (`[a, b]`), block lists (`- a`) and `#`
comments. Quoted values are read as in YAML: `"My \"App\""` is *My "App"*, `'Tobias''s Phone'` is *Tobias's
Phone*. Nested mappings aren’t supported. Mistakes are reported with the line: *`.snapshotkit.yml` could
not be read (line 4: nested mappings are not supported).* Unknown keys are ignored with a note naming them, so a
typo shows up in `snapkit config`.

## The base branch

The branch the Changes tab compares with, highest priority first:

1. the base branch chosen in the app (the Changes tab’s branch menu, or the Run tab),
2. `baseBranch` in `.snapshotkit.yml`,
3. the target branch your CI uses: the GitLab merge request target it checks
   (`$CI_MERGE_REQUEST_TARGET_BRANCH_NAME == "develop"`), or the GitHub `pull_request:` /
   `pull_request_target:` branches (the first without wildcards),
4. `origin/HEAD`, else the first of `develop`, `main`, `master` that exists locally or on `origin`.

When comparing, `origin/<branch>` is used if it exists, so fetch to see the latest state.

## Xcode

SnapshotKit finds installed Xcodes in `/Applications` and `~/Applications` (`Xcode*.app`) plus the one
`xcode-select` points at. (`SNAPSHOTKIT_XCODE_SEARCH_PATHS`, colon-separated, replaces the folders searched.)

1. `developerDir` set: that Xcode, which must exist, also when a version is pinned as well (one in `~/` is in
   the home folder of the Mac the tests run on, also a remote one). If it is another
   version, a note says so: *Using Xcode 16.1 at `/Applications/Xcode-16.1.app` (`developerDir`, from
   .snapshotkit.yml), not Xcode 16.2 as pinned by .gitlab-ci.yml: snapshots may differ from CI’s.*
   `xcode:` in `.snapshotkit.yml` replaces a path CI sets (`DEVELOPER_DIR`, `xcode-select -s`).
2. A version pinned by CI or `xcode:`: the newest installed match. `16` matches any 16.x; `16.2` matches
   16.2 and 16.2.0 but not 16.20.
3. Nothing pinned: the `xcode-select` Xcode (shown as *not pinned by CI; using selected*).

Every command runs with `DEVELOPER_DIR` set to it, so your global `xcode-select` choice doesn’t matter.

## The simulator

The device and OS come from CI’s `-destination`, CI variables or `.snapshotkit.yml`. SnapshotKit lists the
simulators the chosen Xcode knows (`xcrun simctl list devices available`) and picks the one with that name on
that runtime — with `os: latest` or no `os`, on the newest runtime that has a simulator of that name, as
`xcodebuild` would — preferring one that’s already booted. It passes it to `xcodebuild` by id. It never creates, boots or erases simulators itself.

If none matches, the error says what exists and how to get what’s needed — install the runtime
(`xcodebuild -downloadPlatform iOS -buildVersion 18.2`) or create the device (`xcrun simctl create …`) — or
set `device:` / `os:` to one you have.

## Test targets and modules

The **Test target** picker on the Run tab lists every test target that has snapshots: the nearest folder
ending in `Tests` above each `__Snapshots__` folder. Picking one runs `-only-testing:<target>` instead of CI’s
selection; *What CI runs* goes back. `snapkit run --module <target>` does the same once.

## Files and environment variables

| File or variable | What it is |
|---|---|
| `.snapshotkit.yml` | project configuration, at the repository root (committed if you like) |
| `~/Library/Application Support/SnapshotKit/settings.json` | scan folders, pins, recents, preferences, per-project settings |
| `~/Library/Application Support/SnapshotKit/history/` | run history |
| `.git/snapshotkit/` | last run, Viewed marks, record patch journal and backups (per clone, never committed) |
| `.git/snapshotkit/results/` | each repository’s result bundles and failure images (the newest 10 runs; the last run’s are always kept) |
| `SNAPSHOTKIT_HOME` | use another folder instead of `~/Library/Application Support/SnapshotKit` |
| `SNAPSHOTKIT_XCODE_SEARCH_PATHS` | folders to search for Xcode, colon-separated |
| `SNAPSHOTKIT_APP` | the app `snapkit open` opens |

### `settings.json`

The app manages it; edit it only while SnapshotKit isn’t running.

| Key | Meaning |
|---|---|
| `scanRoots` | scan folders |
| `discovered` | projects found by scanning or added |
| `removed` | projects removed from the list, which a rescan leaves out until you open them again |
| `pinned`, `recents` | the sidebar’s Pinned and Recent sections (up to 10 recents) |
| `projectSettings` | per project path: `baseBranch`, `remoteHost`, `module` (the test target) |
| `lastProject` | the project to reopen |
| `flakeIterations` | runs per flakiness check (default 5) |
| `verifyAfterRecord` | verify after re-recording (default `true`) |
| `showMenuBarItem` | the menu bar item (default `false`) |
