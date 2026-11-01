# TestFlight uploads: the agent runs them

User decision, 2026-11-01. Once a build is due, the agent uploads it itself
with `scripts/testflight.sh --upload` — handing the user a command to press is
not the job done. How the script works and what it needs is in
[`CONTRIBUTING.md`](../../CONTRIBUTING.md), *TestFlight*.

## When a build is due

The user asks for one, or the pull request that raises
`CURRENT_PROJECT_VERSION` has been merged (see
[`git-workflow.md`](./git-workflow.md) for the way there). The upload follows
right after that merge, in the same session.

## Before the upload

All of these hold, or there is no upload:

- **The main checkout** (`~/Projects/snotra-mobile`), never a worktree — a
  worktree lacks the git-ignored `Config/Signing.local.xcconfig` and is usually
  behind `main`.
- **On `main`, up to date with `origin/main`, clean.** Xcode's reordering of
  `project.pbxproj` without a change in content may be discarded first.
- **The build number is higher than the last upload's.** The last archive in
  `build/testflight/` shows it
  (`ApplicationProperties:CFBundleVersion` in its `Info.plist`).
- **No other upload is running** (`pgrep -fl testflight.sh`). Two runs share
  the build database and `build/testflight/` and break each other.
- **The tests ran green** on that commit, locally or in CI.

## The run

- Runs outside the sandbox, in the background, its output in a log file.
- Done means `** EXPORT SUCCEEDED **` and *Upload succeeded* in the log; the
  user is told the build number and what it brings, in one or two sentences.
- Apple processes the build for a few minutes before TestFlight shows it.

## Stop and ask

Any doubt wins over the upload:

- a check above fails and the fix is not obvious;
- the script or `xcodebuild` fails for a reason other than a passing glitch —
  signing, provisioning, an expired certificate, App Store Connect refusing the
  build, a missing relay configuration;
- the build would carry something unmerged, or something the user has not seen
  merged;
- anything that would mean changing the signing setup, certificates or the App
  Store Connect record.
