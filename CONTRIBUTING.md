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

## Strings

Every string the user sees goes into `SnotraMobile/Localizable.xcstrings`,
English first and German complete next to it (see
[`.claude/rules/language.md`](.claude/rules/language.md)).
