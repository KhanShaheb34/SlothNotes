# Contributing to Sloth

Sloth is a native macOS notes app written in Swift and AppKit. Contributions that
improve everyday editing, accessibility, reliability, and performance are welcome.

## Set up

Use macOS 13 or later with Xcode or the Xcode command line tools installed.
The app has no third-party package dependencies. Python 3 is needed for the
import-tool tests included in the test script.

From the repository root:

```sh
./scripts/run.sh             # Build and open Sloth
./scripts/build.sh           # Build build/Sloth.app without opening it
./scripts/test.sh            # Run the test suites
./scripts/benchmark-editor.sh # Measure editor performance
```

Application code lives in `Sources/Sloth`, tests in `Tests`, and app resources in
`Resources`. Build output goes into `build` and `.build`.

## Develop with a separate library

Use a temporary library while developing so experiments do not affect your notes:

```sh
./scripts/build.sh
sloth_dev_data="$(mktemp -d "${TMPDIR:-/tmp}/sloth-dev.XXXXXX")"
SLOTH_DATA_DIR="$sloth_dev_data" ./build/Sloth.app/Contents/MacOS/Sloth
```

Keep development data separate from any synced library. Use invented notes and
attachments in tests, screenshots, and bug reports; do not copy fixtures from a
personal note library.

## Make a change

Follow the surrounding Swift style and keep changes focused. Prefer existing
AppKit patterns and small, explicit changes over introducing dependencies or
unrelated refactors.

Add or update tests for behavior that can regress, especially persistence, file
operations, editor interactions, and synchronization. Use temporary directories
and ensure tests clean up their data.

Run `./scripts/test.sh` and build the app before submitting code. Native editor
and workspace tests need a macOS session with AppKit and system services
available; file-coordination failures in a restricted environment may require
rerunning the suite with normal macOS access. For UI changes, also open the app
and check the affected behavior, including light and dark appearance where
relevant. Run the editor benchmark when changing editing performance, and report
the machine and conditions alongside any timing comparison.

Folder-based sync tests verify local exchange behavior. They do not establish
successful upload to iCloud or receipt on another Mac. Describe remote sync
checks separately and report only what was observed.

## Report a bug or submit a pull request

A useful bug report includes the macOS version, reproduction steps, expected
behavior, and what happened. Include a small synthetic example when possible.
Remove private note content, filenames, account details, and local paths from
logs and screenshots.

In a pull request, explain the problem and the resulting behavior, then list
the checks you ran and any remaining limitations. Include screenshots for visible
changes. Keep documentation aligned with changes to build commands, settings,
storage, or user workflows.

Contributions are made under the project's [MIT license](LICENSE).
