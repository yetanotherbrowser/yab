# Contributing to Yab

Thank you for helping. Yab has a long list of reported bugs and a small team, so a well-proven bug fix is the most useful thing you can send. This page gets you from a fresh Mac to a pull request.

Before anything else: security problems are reported privately, see [SECURITY.md](SECURITY.md).

## Product conventions

- **Arc is the reference.** Yab does things the way Arc does. Match Arc's behavior, and copy Arc's timings when Yab does the same thing. Improving on Arc is welcome only when the moment and the result stay the same: smoother, fewer jolts.
- **Requests that diverge from Arc wait for 10 people.** Until then the issue is labeled `arc-divergent` and closed as not planned, with a note that it reopens once 10 people have voted for it or reported it.
- **At 10 or more, it ships as a setting.** Off by default; Arc's way stays the default.
- **Pull requests that change established Arc behavior** without such an issue are declined in review.

## What you need

- A Mac with Apple silicon or Intel, on macOS 15.4 or later.
- Xcode 26 or later, opened once so it finishes installing its components. The Mac app is linked against the macOS 26 SDK.
- Git and Python 3 (both come with Xcode's command line tools).

You do not need an Apple developer account, a signing certificate, or any of the maintainers' machines. Builds you make are signed ad hoc and run on the Mac that built them.

## Build and run

```bash
git clone https://github.com/yetanotherbrowser/yab.git
```

```bash
cd yab
```

```bash
git config core.hooksPath .githooks
```

```bash
./build.sh
```

```bash
open "build/yab Dev.app"
```

`./build.sh` compiles with SwiftPM and wraps the binary into **Yab Dev** (`build/yab Dev.app`), the development build:

- its own bundle id (`dev.serafim.fast.dev`), settings, site data, folder (`~/Library/Application Support/Yab Dev`) and keychain items, so it runs beside an installed Yab without touching it;
- a blueprint icon, so you can tell the two apart;
- it never updates itself.

The first launch may need a right click on the app and **Open**, because a local build is not notarized.

The first `./build.sh` from a clean clone took 13 minutes on an M2 Pro (Xcode 26.5); later builds are incremental. It compiles optimized, in its own folder (`.build/dev-optimized`), so a `swift build` or `swift test` beforehand doesn't speed it up: those make a separate debug build (5 minutes from clean on the same Mac).

If a Developer ID certificate of your own is in your keychain, `build.sh` signs with it. `YAB_SIGN_IDENTITY=- ./build.sh` signs ad hoc anyway.

`swift build` alone builds a debug executable without the app bundle; `swift run Fast` starts it, but some features (extensions, keychain, App Intents) need the bundle, so prefer `./build.sh`.

### Chromium tabs (optional, Apple silicon)

The released Yab bundles the Chromium Embedded Framework (CEF) with Yab's own patches, built from Chromium source. That patched SDK is too large to ship in the repository and takes hours to build, so contributors start from the official CEF build instead:

```bash
CEF_DIR="$(bash scripts/cef/fetch.sh)"
```

```bash
YAB_CEF_DIR="$CEF_DIR" bash YabCore/build.sh
```

```bash
YAB_CEF=1 YAB_UNIVERSAL=0 YAB_CEF_DIR="$CEF_DIR" YAB_CEF_HELPER="<YabCore.app printed above>/Contents/MacOS/YabCore" ./build.sh
```

```bash
open -n -a "build/yab Dev.app" --env YAB_ENGINE=chromium
```

- `scripts/cef/fetch.sh` downloads the pinned official macOS arm64 minimal distribution (about 130 MB) from `cef-builds.spotifycdn.com`, checks its published SHA-1 and keeps it in `~/.local/state/yab-spike-cef`.
- `YabCore/build.sh` builds the page helper with CMake (installed into its build folder with pip if you don't have it).
- From a clean clone on an M2 Pro: the download 25 seconds, YabCore 11 minutes, the app with CEF inside 18 minutes.
- Features that depend on Yab's CEF patches (`YabCore/cef-patches`) are missing or fall back on the stock build. A bug that only shows on Chromium tabs in the released app may not reproduce here; say so in the issue or pull request, and a maintainer will check it on the patched build.

More in [docs/cef-packaging.md](docs/cef-packaging.md) and [docs/chromium-tabs.md](docs/chromium-tabs.md).

### The iPhone app

`Phone/` is the iPhone app, generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `Phone/project.yml`:

```bash
cd Phone && xcodegen generate && open YabPhone.xcodeproj
```

Set your own team under Signing & Capabilities (the project names the maintainers' team) and run it in an iOS 26 simulator. Its rules are in [Phone/AGENTS.md](Phone/AGENTS.md).

## Tests and checks

| Command | What it checks | Needs |
|---|---|---|
| `swift test --filter "$(scripts/runs/tests_for.py)"` | The suites that cover the files you changed (picked by name) | A logged-in Mac |
| `swift test --filter SomeSuiteTests` | One suite | A logged-in Mac. Tests that show windows skip themselves when no screen is free (`Tests/FastTests/TestScreen.swift`). |
| `swift test --filter MailCoreTests` | The mail engine alone, without the app (144 tests, 4 minutes from clean) | Nothing |
| `./design-check --head` | Lines you added in `Sources/` keep to the design system (`Sources/YabDesign`) | Python 3 |
| `scripts/swift-parse-check` | Staged Swift files parse | Xcode |

The pre-commit hook (`.githooks/pre-commit`) runs the last two on every commit. CI runs the same checks on your pull request with `--base`, against the branch you are merging into.

The whole `swift test` does not finish on a clean Mac yet: its XCTest half passes (302 tests, one known failure in `QuietSitesTests`), then the swift-testing half stalls after about 170 of 4,300 tests. Until that is fixed, run the suites for what you changed, as CI does. Two suites also fail outside the maintainers' machines today: `TuneWatchLifecycleTests` expects their test environment, and `MailSlotsTests.zonesAsPeopleWriteThem` depends on the Mac's time zone names. Mention them in your pull request only if your change touches them.

### Driving a running Yab from the shell

Turn on **Settings › Developers › Let agents use Yab** in Yab Dev and it listens on a Unix socket in its own folder, readable by your user only. `./bench` speaks it:

```bash
./bench --dev open https://example.com
```

```text
./bench --dev wait TAB          # until it has loaded
./bench --dev text TAB          # the page's text
./bench --dev shot TAB out.png  # a picture of it
./bench --dev click TAB "button.go"
./bench --dev probe             # the windows, panels and modals open now
./bench --dev close all
```

Bench tabs are never selected for you, never enter the session or history, and go when the script says so. This is how Yab is tested while someone is using it.

## Making a change

1. **Find or open an issue.** For anything bigger than a small bug fix, say in the issue what you plan before you write it, so nobody's work is wasted. Comment on an issue to take it.
2. **Fix the cause, not the symptom.** No retries, timers, delays or "try again" loops that hide a race. If a bug keeps coming back, find the structure that lets it, and fix that.
3. **Prove it, with the cheapest proof that shows the bug and the fix:**
   - Logic, state, parsing, a wrong value: a unit test that fails before your change and passes after. Say so in the pull request: "fails on main, passes here".
   - Anything people see or feel (layout, motion, a control, copy on screen): a screenshot or short recording before and after.
   - Performance: numbers before and after, measured the same way on the same Mac.
   - Docs, copy and constants need no proof beyond the diff.
4. **Visible changes need a yes first.** A change to how something looks, where it sits or what it says is shown to a maintainer as a picture before it is built. Fixing something back to how it already looked needs no approval.
5. **Keep to the design system.** Cards use `.cardFrame()`, corners are `Radius` steps, spacing and type are on the scale in `Sources/YabDesign`, buttons are `.yab(kind, size)`, tooltips are Yab's own (`.keyTip`, never `.help`). `./design-check` enforces it; a line that must break a rule says why: `// design: <reason>`.
6. **New menu actions are also commands.** A menu item is not finished until the same action is found in the command field (`Sources/Fast/Query.swift`). A new Settings row must be classified in `Sources/Fast/NativeActions.swift` so Yab's own agent can change it; `NativeControlTests` fails until it is.
7. **Open a pull request** against `main` and fill in the template.

### Style

- Swift 6 toolchain, Swift 5 language mode. SwiftUI for what is drawn, AppKit where SwiftUI doesn't reach.
- Comments say why, in plain sentences.
- Words in the app, docs and commits are American English. No em dashes; use a comma, a colon or two sentences.
- Commit messages: a short subject line saying what changes for the person using Yab or for the code, then the why.

## Reviews

Every pull request runs CI on GitHub's macOS runners. A maintainer reads every new pull request by hand, about once an hour during the working day, may ask for more proof, and merges. There is no automatic review or bot. The whole path from report to release: [docs/open-source/process.md](docs/open-source/process.md).

## Where to start

- [docs/architecture.md](docs/architecture.md): a map of the code.
- [docs/index.md](docs/index.md): how each part works, one page per area.
- Issues labeled `good first issue` and `help wanted`.
