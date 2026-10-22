# Developing Lumio

How to build, test, debug and release Lumio. For what the app does, see the [README](../README.md).
Design details: [core-api.md](core-api.md), [schema.md](schema.md) and
[reconnect-state-machine.md](reconnect-state-machine.md).

## Requirements

- Mac with Apple silicon, macOS 14 or later
- Xcode 27.1 (Swift 6.4). Xcode 26.6 also builds it; that's what GitHub's CI uses.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- For releases: the [GitHub CLI](https://cli.github.com) (`brew install gh`, then `gh auth login`)

## Getting started

```bash
xcodegen
open IPTVStreamer.xcodeproj
```

`xcodegen` reads `project.yml` and writes `IPTVStreamer.xcodeproj`, which is generated and not
committed. Run it again after pulling changes or editing `project.yml`. Swift files added inside
`Packages/IPTVKit` are picked up without it. The first open takes a while: MPVKit downloads about
550 MB of prebuilt frameworks (SwiftPM also fetches the GPL variants, but they're never linked).

The project and package keep the app's first name (`IPTVStreamer.xcodeproj`, `IPTVKit`, bundle ID
`com.jackson.iptvstreamer`), so existing libraries, logins and settings carry over.

| In Xcode | How |
|---|---|
| Pick what to run | Scheme **IPTVMac**, destination **My Mac** |
| Build and run / stop | **⌘R** / **⌘.** |
| Run all tests / one test | **⌘U** / the ◇ next to a `@Test` |
| Logs | Debug area (**⇧⌘Y**) |
| Clean build | **⇧⌘K** |

Tests use **Swift Testing** (`import Testing`), which works like pytest: `@Test` marks a test,
`#expect(a == b)` is `assert a == b`, and `@Test(arguments:)` is `@pytest.mark.parametrize`.

From the terminal:

```bash
swift test --package-path Packages/IPTVKit
xcodebuild -project IPTVStreamer.xcodeproj -scheme IPTVMac -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData.noindex build
```

**Installing your own copy:** `Tools/install.sh` builds the Release version and installs it as
`/Applications/Lumio.app` (quit Lumio first). Your library, logins and settings live outside the
app, so they're kept. Build output goes to `build/DerivedData.noindex`; the `.noindex` ending keeps
build copies out of Spotlight. Debug builds register themselves with LaunchServices when run, so
unregister one after testing if it shows up in Spotlight:
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <path to the .app>`.

## Project layout

```
project.yml                 XcodeGen spec: the app, its installer service, versions, update settings
Config/Signing.xcconfig     Code signing for Xcode builds (ad-hoc; releases are re-signed by sign_app.sh)
App/IPTVMac/                The macOS app target: entry point, windows, menus
App/LumioInstaller/         XPC service that installs signed updates (the app is sandboxed)
Packages/IPTVKit/           Swift package with all the app logic
  Sources/IPTVCore/         Models, database, Keychain, Xtream client, sync, EPG, playback state
                            machine. Foundation + GRDB only.
  Sources/IPTVPlayback/     Playback engines: mpv (MPVKit) and AVPlayer
  Sources/IPTVUI/           SwiftUI views and view models
  Sources/LumioUpdate/      Update signatures and installing (Foundation + CryptoKit)
  Tests/                    Swift Testing suites and fixtures
Docs/                       This guide, the schema, the core API, the reconnect state machine
Tools/StreamHarness/        Fake Xtream provider with fault injection, for testing
Tools/Release/              make_release.sh, publish.sh, sign_app.sh, sign_update.swift,
                            make_signing_certificate.sh
Tools/install.sh            Build and install your own copy in /Applications
Tools/check_secrets.py      Fails if anything git would publish contains a credential
Tools/AppIcon/              Icon artwork and the script that builds the icon set
.github/workflows/ci.yml    Secrets check, tests and a Release build on every push
```

Dependencies: **GRDB** (SQLite) and **MPVKit 1.0.0** (libmpv + FFmpeg, the LGPL product only).
No others without asking first. When a dependency or its version changes, update
[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) (it lists every bundled library, its version
and licence, and ships inside the app).

## Where data lives

The app is sandboxed, so its files are in its container:

| What | Where |
|---|---|
| Library (catalog, guide, favorites, settings) | `~/Library/Containers/com.jackson.iptvstreamer/Data/Library/Application Support/IPTVStreamer/iptv.sqlite` |
| Provider usernames and passwords | macOS Keychain, service `com.jackson.iptvstreamer.provider` |
| Image cache | `~/Library/Containers/com.jackson.iptvstreamer/Data/Library/Caches/IPTVStreamer/Images` |

To start over, quit Lumio, delete the `IPTVStreamer` folder and remove the Keychain items.
`sqlite3 <path to iptv.sqlite> ".tables"` shows the database. Once Lumio is signed with its
certificate (below), macOS keeps other apps out of its data folder, so this says "authorization
denied" unless Terminal has Full Disk Access (System Settings → Privacy & Security).

**Signing and Keychain prompts.** macOS lets an app read its Keychain items only while its
signature matches the one that saved them. Releases and `Tools/install.sh` sign Lumio with the
self-signed "Lumio Release Signing" certificate (`Tools/Release/sign_app.sh`), so every version
has the same signature and reads the saved logins without asking. Builds run from Xcode are
signed ad-hoc, which changes with every build: if one reads the real library, macOS asks for your
password ("Lumio wants to use your confidential information"). That's why Debug runs use
`-databaseName`, which keeps logins in memory.

## Debugging

- **Logs** use `os.Logger`, subsystem `com.jackson.iptvstreamer`, categories `app`, `database`,
  `network`, `sync`, `epg`, `connections`, `playback` and `security`. Outside Xcode, use
  Console.app or `/usr/bin/log show --last 10m --info --predicate 'subsystem == "com.jackson.iptvstreamer"'`
  (in zsh, plain `log` is a built-in, so use the full path). Credentials are never logged.
- **Stream info** in the player (**D** or the ⓘ button): engine, format, codecs, resolution, fps,
  decoder, buffer, dropped frames and the stream URL with credentials masked.
- **SwiftUI previews** (**⌥⌘↩** in a view file) use an in-memory database.
- **Release-only crashes:** the hardened runtime kills anything that generates code at run time
  (mpv's Lua scripts did, so they're off in `MPVEngine`). Look for "Code Signature Invalid".
- **Video size:** mpv reads its layer size only when the video output starts, so `MPVVideoView`
  waits for resizes to settle and `MPVEngine.matchOutputToDrawable()` recreates the output if mpv's
  size and the layer's differ.

## Testing against the stream harness

`Tools/StreamHarness/harness.py` is a fake Xtream provider (Python + ffmpeg) with three test
channels (H.264, HEVC with AC-3, 50 fps with E-AC-3), a guide, movies and series. It can stall,
drop, throttle, return any HTTP status or enforce a connection limit; see
[scenarios.md](../Tools/StreamHarness/scenarios.md). Credentials are `test` / `test`.

```bash
python3 Tools/StreamHarness/harness.py --port 8098
```

Options: `--region-prefixes` (and `=alt` for other spellings) names groups like a real provider;
`--renumber` serves the same catalog under new IDs, like a provider moving panels.

Debug-build test runs. Each uses its own throwaway library and in-memory credentials, never your
real ones (`-databaseName NAME` → `dev-NAME.sqlite`):

| Run the Debug app with | What it does |
|---|---|
| `-databaseName dev -harness http://127.0.0.1:8098` | Opens with the harness added, to try things by hand |
| `-databaseName smoke -smokeTest http://127.0.0.1:8098 -smokeTestB http://127.0.0.1:8099 -smokeTestMoved http://127.0.0.1:8097` | End-to-end run of every section (two providers, plus a renumbered one), logging `SMOKE …` lines; any `FAIL` is a problem. Saves screenshots to the container's tmp folder. |
| `-databaseName layout -layoutTest http://127.0.0.1:8098` | Every section at three window sizes; prints `OVERFLOW` for anything past the edge |
| `-databaseName probe -playProbe http://127.0.0.1:8098 -probeChannel 2 -probeSeconds 30` | Plays one channel and logs buffer, drops and decoder every 2 s |
| `-databaseName soak -smokeTest http://127.0.0.1:8097 -soakMinutes 240 -soakTiles 4` | Long playback run for memory checks |
| `-databaseName perf -perfTest YES` | Guide drawing timings |
| `-databaseName clip -guideClipTest YES` (with `IPTV_DEV_SEED=1`) | Scrolls the guide and checks nothing is drawn outside it |

Add `-openSection settings` (any sidebar section) to open on a section, and `-snapshotAfter 6`
to save the whole window after that many seconds. Snapshots go to the container's tmp folder,
which Terminal can't read once Lumio is certificate-signed; `-snapshotStdout YES` also prints
each one as a `SNAPSHOT-PNG name base64` line.

Also: `IPTV_TRACE_LAUNCH=1 IPTV_DEV_DATABASE=launch IPTV_DEV_SEED=1 "<app>/Contents/MacOS/Lumio"`
prints launch timings (any build; a throwaway library with 300 synthetic channels), and
`IPTV_PERF_PROGRAMMES=700000 swift test --filter largeGuideImportsWithFlatMemory` (in
`Packages/IPTVKit`) runs the big guide-import benchmark.

## Performance

Measured on this Mac against the harness (so network quality isn't included):

| Target | Result |
|---|---|
| Launch to a usable window < 1 s | 0.57–0.60 s (Release); about 1 s on the first launch after a new build |
| Channel switch to first frame < ~2 s | 0.3–1.9 s (H.264 720p, HEVC 1080p/AC-3, H.264 50 fps/E-AC-3) |
| Smooth guide with 1,000+ channels × 7 days | 1,500 channels × 8 days (576,000 programmes): frame draw median 0.5 ms, p95 9 ms |
| Stable memory, 4 h of live playback | Flat after the first 30 min (+4 MB over 2.5 h); survived sleep |
| Stable memory, 4-tile multiview | Not flat: about +2 MB a minute after the first hour (not investigated yet) |
| Large guide import | 700,000 programmes (~150 MB XML) in 44 s, peak memory growth 13 MB |

Four simultaneous mpv players (H.264 + HEVC 1080p) all decode on VideoToolbox with 0 dropped
frames. Search across everything returns in about 60 ms.

## App icon

Built from `Tools/AppIcon/source.jpg` by `swift Tools/AppIcon/make_icon.swift`, which writes every
size into `App/IPTVMac/Assets.xcassets/AppIcon.appiconset`. If the Dock keeps the old icon, run
`killall Dock`.

## Releasing

Lumio is published at https://github.com/jacksonf-netizen/lumio. Friends install it from the
Releases page, and their copies update themselves from there.

Once per Mac: `Tools/Release/make_signing_certificate.sh` makes the signing certificate (see
"Signing and Keychain prompts" above), and the update signing key must be in your Keychain (below).

1. Test the changes (`swift test`, a smoke run, `Tools/install.sh` to use it yourself).
2. In `project.yml`, bump `MARKETING_VERSION` (`0.1.0` → `0.2.0`, or `0.1.1` for small fixes) and
   `CURRENT_PROJECT_VERSION` (+1).
3. In `CHANGELOG.md`, move the notes under `## Unreleased` into a new `## 0.2.0 — <date>` section.
   Start the section with a one- or two-sentence summary paragraph, then the list. The summary
   is all Lumio shows when it offers the update; the list is on the release page.
4. Commit, then run `Tools/Release/publish.sh`.

`publish.sh` refuses to run with uncommitted changes, an existing tag or no changelog section. It
runs the secrets check, builds and signs the release (`make_release.sh`), tags `vX.Y.Z`, pushes,
and creates the GitHub release with the `.dmg` (new installs), the `.zip` and `.zip.sig` (updates)
and `SHA256SUMS.txt`. The release notes it writes include the install steps and the "no content,
bring your own login" notice.

5. Check the update works: let an older copy (or a Debug copy built with an older
   `MARKETING_VERSION`, kept outside Applications) update itself, and download the new `.dmg`.
6. Then delete the previous release so only the latest is offered:
   `gh release delete vOLD --repo jacksonf-netizen/lumio --yes`. Keep its git tag, so its source
   stays available.

**The signing keys.** There are two, both only in your login Keychain, never in the repository.
Back both up.

- The update key (Ed25519, made by `swift Tools/Release/sign_update.swift generate`; item "Lumio
  update signing key", account `release`). Its public half is `UPDATE_PUBLIC_KEY` in
  `project.yml`, built into every copy, and `make_release.sh` refuses to sign if they don't match.
  Without it, existing copies won't accept new updates and everyone has to reinstall by hand.
  Back it up from Keychain Access (the item → Show password → your password manager); on a new
  Mac, add the item back with the same name and account.
- The code signing certificate "Lumio Release Signing" (Keychain Access → My Certificates).
  Without it, a new one works, but everyone's copy asks for their password once more after the
  next update. Back it up with File → Export Items… (a password-protected .p12) and import that
  on a new Mac.

`make_release.sh` won't make an ad-hoc signed release unless you set `ALLOW_ADHOC=1` (for test
builds only).

**Trying the install path locally**, without publishing: serve `build/release` with
`python3 -m http.server 8123`, then run a Debug copy built with `MARKETING_VERSION=0.0.9` (copied
outside Applications, since it replaces itself) with
`-databaseName updtest -updateTestVersion 0.1.0 -updateTestArchive http://127.0.0.1:8123/Lumio-0.1.0.zip -updateTestSignature http://127.0.0.1:8123/Lumio-0.1.0.zip.sig`.
`-checkUpdatesAtLaunch YES -updateTestAutoInstall YES` instead tries the real GitHub release.
Debug builds don't check for updates otherwise.

**Signing without the first-launch warning** needs a paid Apple Developer account. Set
`DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"` and `NOTARY_PROFILE=<profile>` when
running the scripts; the top of `make_release.sh` shows how to create the profile.

**Secrets.** `python3 Tools/check_secrets.py` looks through every file git would publish for your
providers' addresses (read from the app's database), anything in `LocalSecrets.json`, and keys or
tokens. `publish.sh` and CI run it. To run it before every commit:
`printf '#!/bin/sh\npython3 Tools/check_secrets.py\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit`.

**CI** runs on every push to `main` (the repository's Actions tab). GitHub's runners use Xcode
26.6, whose compiler crashes on one Swift pattern: a function passed straight to `Binding(set:)`.
Write `set: { update($0) }` instead of `set: update`.
