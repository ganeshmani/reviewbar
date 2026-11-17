# Contributing to ReviewBar

Thanks for taking a look. ReviewBar is a small Swift app, so getting set up is quick.

## Ways to help

- **Report a bug.** Use the [bug report form](https://github.com/ganeshmani/reviewbar/issues/new?template=bug_report.yml). Logs and steps to reproduce make bugs fixable.
- **Suggest a feature.** Open a [feature request](https://github.com/ganeshmani/reviewbar/issues/new?template=feature_request.yml) and describe the problem before the solution.
- **Send a pull request.** For anything bigger than a small fix, open an issue first so we can agree on the approach before you spend time on it.
- **Good first issues** are labelled [`good first issue`](https://github.com/ganeshmani/reviewbar/labels/good%20first%20issue).

## Setup

You need macOS 14+ and Xcode 16+ (or the Swift 6 toolchain).

```bash
git clone https://github.com/ganeshmani/reviewbar && cd reviewbar
swift test                        # core logic tests
swift build && .build/debug/ReviewBar --demo --open   # run with sample data, no accounts needed
scripts/build-app.sh --install    # build the .app, copy to ~/Applications, launch
```

## Project layout

| Path | What's there |
|---|---|
| `Sources/ReviewBarCore/` | Everything testable without UI: models, SQLite store, GitLab/GitHub clients, engine runner, shell helpers |
| `Sources/ReviewBar/` | The SwiftUI + AppKit app: menu bar popover, inbox, review detail, settings |
| `Sources/ReviewBar/Demo.swift` | Sample data and the `--snapshot` renderer |
| `Tests/ReviewBarCoreTests/` | Swift Testing tests for the core |
| `website/` | The static landing page |

## Pull request checklist

- `swift test` passes.
- New logic in `ReviewBarCore` comes with a test.
- UI changes include a before/after screenshot. `ReviewBar --demo --snapshot <dir>` renders every screen in light and dark.
- Don't block the main thread. Anything that spawns a process (`Shell.which`, `Shell.capture`) or touches the network runs off the main actor.
- Keep the safety rules intact (see below). PRs that weaken them won't be merged.

## Safety rules

ReviewBar acts on other people's merge requests, so these are non-negotiable:

1. Nothing is posted, approved or commented without an explicit user action and confirmation.
2. Every write re-checks the MR's head SHA first.
3. Engines run read-only. Forge tokens and `ANTHROPIC_*` / `OPENAI_*` keys never reach the engine's environment.
4. Findings only anchor to lines in the reviewed diff.

## Commit style

Short imperative subject line ("Fix popover jumping on tab switch"), with a body explaining why if it isn't obvious.

## Releasing (maintainers)

1. Bump `VERSION` in `scripts/build-app.sh` and add an entry to `CHANGELOG.md`.
2. `SIGN_ID="Developer ID Application: …" scripts/build-app.sh`, package the DMG, notarize and staple it.
3. `gh release create vX.Y.Z ReviewBar-X.Y.Z.dmg ReviewBar.dmg` (the second is a copy with a fixed name; the website links to `releases/latest/download/ReviewBar.dmg`).
4. Update `version` and `sha256` in [`ganeshmani/homebrew-tap`](https://github.com/ganeshmani/homebrew-tap/blob/main/Casks/reviewbar.rb).

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
