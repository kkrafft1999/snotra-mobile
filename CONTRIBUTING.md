# Contributing to Snotra mobile

How work is organised — branches, pull requests, issues — is described in
[`.claude/rules/git-workflow.md`](.claude/rules/git-workflow.md) and
[`.claude/rules/task-management.md`](.claude/rules/task-management.md).

## Prerequisites

- A Mac with **Xcode 27.1** or later, selected as the active developer
  directory and with its license accepted:
  ```sh
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept
  xcodebuild -runFirstLaunch
  ```
- The **iOS simulator runtime** (several GB):
  ```sh
  xcodebuild -downloadPlatform iOS
  ```

## Build and test

Open `SnotraMobile.xcodeproj` in Xcode and run the `SnotraMobile` scheme, or
from the command line:

```sh
xcodebuild build -project SnotraMobile.xcodeproj -scheme SnotraMobile \
  -destination 'generic/platform=iOS Simulator'

xcodebuild test -project SnotraMobile.xcodeproj -scheme SnotraMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

`xcrun simctl list devices available` lists the simulators to pick from.
Tests use [Swift Testing](https://developer.apple.com/documentation/testing).

The same test run is the required check `Tests (iOS simulator)` on every pull
request ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)); `main`
accepts nothing that has not passed it.

## Running on an iPhone

Signing is automatic, with the Apple team kept out of the repository:

1. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig`
   (git ignores it) and put in your team id.
2. Sign in under *Xcode › Settings › Apple Accounts*.
3. Connect the iPhone, trust the Mac, and turn on *Settings › Privacy & Security
   › Developer Mode* on the phone.
4. Pick the iPhone as the run destination and run the `SnotraMobile` scheme.

## TestFlight

For a phone that cannot turn on Developer Mode (one managed by an MDM, for
example), the app goes out through TestFlight. The App Store Connect record
exists (bundle id `dev.snotra-ai.mobile`); the build is signed at export with
the team from `Config/Signing.local.xcconfig`, so no registered device is
needed.

1. Raise `CURRENT_PROJECT_VERSION` in the project — App Store Connect takes each
   build number once.
2. Put the production relay's configuration in a file outside the repository,
   by default `~/env/snotra-mobile/relay.env` (another path through
   `SNOTRA_RELAY_ENV`), shaped like `Config/relay.env.example` and readable by
   you alone (`chmod 600`). Environment variables of the same names take
   precedence. The script writes the values into
   `SnotraMobile/Relay/ProductionRelay.local.swift`, which git ignores; a release
   build does not compile without it, so an archive from Xcode needs one run of
   the script first.
3. Run `scripts/testflight.sh --upload`. Without `--upload` it only builds and
   exports into `build/testflight/` (ignored by git).
4. Once App Store Connect has processed the build, answer the export-compliance
   question for it under *TestFlight*, then install it with the TestFlight app on
   the iPhone of an internal tester.

## Strings

Every string the user sees goes into `SnotraMobile/Localizable.xcstrings`,
English first and German complete next to it (see
[`.claude/rules/language.md`](.claude/rules/language.md)).
