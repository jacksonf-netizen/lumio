# Lumio

Lumio is a native macOS IPTV player for Xtream Codes providers, written in Swift and SwiftUI.
Live TV first, built for streaming reliability, with multi-provider support. Movies and series are
secondary. Personal use only; the app ships no content.

It was called IPTV Streamer at first. Internal names (the bundle ID `com.jackson.iptvstreamer`, the
Keychain service, the data folder, the Xcode project `IPTVStreamer.xcodeproj` and the Swift package
`IPTVKit`) keep the old name, so existing providers, favorites and settings carry over.

**Status: all 7 phases built** and published on GitHub, with updates that install themselves.
See the [Roadmap](#roadmap), the [Performance](#performance) report,
[What's not done](#whats-not-done-yet) and [Publishing and updates](#publishing-and-updates).

## Install Lumio

You need a Mac with Apple silicon (M1 or later), macOS 14 or later, and your own IPTV
subscription (an Xtream Codes login from your provider). Lumio comes with no channels.

1. Download the latest **Lumio-x.y.z.dmg** from
   [Releases](https://github.com/jacksonf-netizen/lumio/releases/latest), open it and drag
   Lumio to Applications.
2. The first time you open it, macOS says it can't check Lumio for malicious software (Lumio isn't
   signed with a paid Apple developer certificate). Click **Done**, then open **System Settings →
   Privacy & Security**, scroll down, click **Open Anyway** next to Lumio and confirm. You only do
   this once.
3. In Settings → Providers, add your provider's server address, username and password.

Lumio checks for a new version each time it opens. When there is one, it asks; say yes and it
downloads the update, checks it's genuine, installs it and reopens. You can turn the check off in
Settings → About.

---

## Requirements

- Mac with Apple silicon, macOS 14 or later
- Xcode (built with Xcode 27.1 / Swift 6.4)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## First-time setup

```bash
cd ~/Documents/"IPTV Streamer"
xcodegen
open IPTVStreamer.xcodeproj
```

`xcodegen` reads `project.yml` and writes `IPTVStreamer.xcodeproj`. The project file is generated
output and isn't committed. Re-run `xcodegen` whenever you pull changes or edit `project.yml`.
Swift files added inside `Packages/IPTVKit` are picked up automatically and don't need it.

The first open takes a minute while Xcode downloads the GRDB package.

## Build, run, test (in Xcode)

| Do this | How |
|---|---|
| Pick what to run | Scheme menu (top of the window, next to the ▶ button) → **IPTVMac**, destination **My Mac** |
| Build and run | **⌘R** (or the ▶ button) |
| Stop | **⌘.** |
| Run all tests | **⌘U**. Results appear in the Test navigator (**⌘6**). |
| Run one test | Click the ◇ diamond next to a `@Test` in the editor gutter |
| See logs | Debug area at the bottom (**⇧⌘Y**) |
| Clean build | **⇧⌘K**, then ⌘R |

Python comparison: tests use **Swift Testing** (`import Testing`). It works like pytest:
`@Test` marks a test function, `#expect(a == b)` is `assert a == b`, and
`@Test(arguments: [...])` is `@pytest.mark.parametrize`.

## Build and test from the terminal

Package tests only (fast, no app):

```bash
cd "Packages/IPTVKit" && swift test
```

Whole app plus tests:

```bash
xcodebuild -project IPTVStreamer.xcodeproj -scheme IPTVMac -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData.noindex build test
```

Launch the app built by that command (a development copy with its own test library):

```bash
open "build/DerivedData.noindex/Build/Products/Debug/Lumio.app"
```

### Installing the app you use day to day

```bash
Tools/install.sh
```

This builds the Release version and installs it as **/Applications/Lumio.app**, replacing
the previous copy (and removing the old IPTV Streamer.app from before the rename). Open it from Applications, Launchpad, Spotlight or the Dock. Run the script
again after pulling changes (quit the app first). Your providers, favorites and settings are kept,
because they live in the app's data folder, not inside the app.

Build output goes to `build/DerivedData.noindex`. The `.noindex` ending keeps Spotlight from
listing those build copies, so only the installed app shows up.

## Debugging

- **Breakpoints:** click the line number in the editor gutter, then run with ⌘R. Execution stops
  there. Inspect variables in the debug area, and step with F6 (over) and F7 (into).
  Breakpoints are like `breakpoint()` in Python.
- **Logs:** the app uses `os.Logger` (see `IPTVCore/Support/Log.swift`). Logs show in Xcode's
  console. To see them outside Xcode, open **Console.app**, click Start, and search
  `subsystem:com.jackson.iptvstreamer`. Categories are `app`, `database`, `network`, `sync`,
  `epg`, `connections`, `playback` and `security`. Credentials are never logged.
- **SwiftUI previews:** open a view file such as `RootView.swift` and press **⌥⌘↩** to show the
  canvas. Previews use an in-memory database, so they never touch your real data.
- **Try the app against the test server:** start the harness
  (`python3 Tools/StreamHarness/harness.py --port 8098`), then in Xcode choose
  **Product › Scheme › Edit Scheme… › Run › Arguments** and add `-databaseName dev -harness http://127.0.0.1:8098`.
  The Debug app then opens with the harness already added, in a separate throw-away database
  (your real library and Keychain are untouched).
- **Video size after resizing:** mpv only reads the size of its drawing layer when its video
  output is set up, not when the window is resized or enters full screen. `MPVVideoView` waits
  for the size to settle, then `MPVEngine.matchOutputToDrawable()` compares mpv's `osd-width`/
  `osd-height` with the layer and recreates the output if they differ. The smoke test logs
  `matches=true/false` for windowed, full-screen, restored and minimum-size windows.
- **Layout check:** run the Debug app with `-databaseName layout -layoutTest http://127.0.0.1:8098`.
  It visits every section at the minimum, a medium and a large window size and prints `OVERFLOW`
  for anything laid out past the window edge.
- **Release-only crashes:** Release builds run with the hardened runtime, which kills the app if
  anything generates code at run time. mpv's built-in Lua scripts did that, so they're switched off
  in `MPVEngine`. If a crash only happens in Release, check the crash report for
  "Code Signature Invalid".

## App icon

The icon is built from `Tools/AppIcon/source.jpg`. To change it, replace that file and run
`swift Tools/AppIcon/make_icon.swift`. It writes every size into
`App/IPTVMac/Assets.xcassets/AppIcon.appiconset`. macOS caches icons, so the Dock may show the old
one until you restart the Dock (`killall Dock`).

## Where data lives

The app is sandboxed, so its files live in its container:

| What | Where |
|---|---|
| Database (catalog, EPG, favorites, settings) | `~/Library/Containers/com.jackson.iptvstreamer/Data/Library/Application Support/IPTVStreamer/iptv.sqlite` |
| Provider usernames and passwords | macOS Keychain, service `com.jackson.iptvstreamer.provider` (items added before the rename are labelled "IPTV Streamer provider", newer ones "Lumio provider") |

To reset everything, quit the app, delete that `IPTVStreamer` folder, and remove the Keychain items.

You can inspect the database with the built-in `sqlite3` tool:

```bash
sqlite3 ~/Library/Containers/com.jackson.iptvstreamer/Data/Library/Application\ Support/IPTVStreamer/iptv.sqlite ".tables"
```

### Keychain prompts after rebuilding

By default the app is signed "to run locally", which needs no Apple account. That signature
changes on every build, so macOS may ask "Lumio wants to use your confidential
information" after a rebuild. Click **Always Allow**. To stop the prompts for good:

1. Xcode → Settings → Accounts → add your Apple ID. A free "Personal Team" is enough.
2. Note the Team ID shown there.
3. Create `Config/Local.xcconfig` (git-ignored) containing `DEVELOPMENT_TEAM = YOURTEAMID`.
4. Run `xcodegen` again.

## Project layout

```
project.yml                 XcodeGen spec for the app target and scheme
Config/Signing.xcconfig     Code-signing defaults (+ optional git-ignored Local.xcconfig)
App/IPTVMac/                macOS app target: entry point, windows, menus (AppKit-only code goes here)
Packages/IPTVKit/           Local Swift package with all app logic
  Sources/IPTVCore/         Models, database, Keychain, services. Foundation + GRDB only.
  Sources/IPTVPlayback/     Playback engines (phase 3)
  Sources/IPTVUI/           SwiftUI views and @Observable view models
  Tests/                    Swift Testing suites + Fixtures/
Docs/                       Schema, core API, reconnect state machine
Tools/StreamHarness/        Local fault-injecting test stream server (phase 3)
Tools/Release/              make_release.sh: build, sign, notarize, package a release
Tools/check_secrets.py      Fails if anything that would be committed contains a credential
Tools/AppIcon/              Source artwork and the script that builds the app icon
.github/workflows/ci.yml    GitHub Actions: secrets check, unit tests, Release build
CHANGELOG.md                What changed in each version
THIRD-PARTY-NOTICES.md      Licences of GRDB, MPVKit and the libraries it bundles (shown in the app)
LocalSecrets.example.json   Template for git-ignored LocalSecrets.json (manual testing only)
```

Dependencies: **GRDB** (SQLite) and **MPVKit 1.0.0** (libmpv + FFmpeg, the LGPL product only).
No others will be added without asking. MPVKit downloads about 550 MB of prebuilt frameworks the
first time Xcode resolves packages; SwiftPM also fetches the GPL variants, but they are never linked.

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 | Skeleton, provider-keyed models, Keychain, database + migrations, app shell | ✅ Done |
| 2 | Xtream client, multi-provider catalog sync, EPG import, ConnectionManager, channel matching | ✅ Done |
| 3 | mpv + AVPlayer engines, reconnect/failover state machine, local stream test harness | ✅ Done |
| 4 | Live TV UI, channel switching, EPG guide grid, channel management | ✅ Done |
| 5 | Movies and Series | ✅ Done |
| 6 | Multiview | ✅ Done (built early; the player's M key needed it) |
| 7 | Search, settings, export/import, polish, performance pass | ✅ Done (4-hour soak results below) |

## Performance

Measured on this Mac (Apple silicon, macOS 27). The test streams come from the local harness, so
network quality isn't part of these numbers.

| Target | Result |
|---|---|
| Cold launch to usable cached UI < 1 s | **0.57–0.60 s** (Release, normal launch); about 1.0 s on the very first launch after a new build |
| Channel switch to first frame < ~2 s | **1.06–1.9 s** (H.264 720p, HEVC 1080p/AC-3, H.264 50 fps/E-AC-3) |
| Smooth guide, 1,000+ channels × 7 days | **1,500 channels × 8 days (576,000 programmes)**: frame draw median 0.5 ms, p95 9 ms (Debug build) |
| Stable memory, 4 h live playback | Flat: 281 MB → 334 MB in the first 30 min, then +4 MB over the next 2.5 h. 0 reconnects. Survived a 1 h sleep and resumed on wake (the run stopped at 3 h of its planned 4). |
| Stable memory, 4-tile multiview | Not flat: 547 MB → 962 MB over 3 h, rising about 2 MB/min after the first hour. 0 reconnects; resumed after sleep. Cause not investigated yet (see "What's not done yet"). |
| Large guides import without blocking or bloating | 700,000 programmes (~150 MB XML) in 44 s, peak memory growth 13 MB |

Other observations:
- Four simultaneous mpv players (H.264 + HEVC 1080p) all decode on VideoToolbox with 0 dropped
  frames when visible (render check in `scenarios.md`).
- Search across channels, programmes, movies and series returns in about 60 ms.

How to re-run:
- **Guide import**: `cd Packages/IPTVKit && IPTV_PERF_PROGRAMMES=700000 swift test --filter largeGuideImportsWithFlatMemory`.
- **Launch time**: in Terminal, `IPTV_TRACE_LAUNCH=1 IPTV_DEV_DATABASE=launch IPTV_DEV_SEED=1 "<app>/Contents/MacOS/Lumio"`
  prints milestones. That uses a throwaway library, never your real one.
- **Guide drawing**: run the Debug app with `-databaseName perf -perfTest YES`.
- **Guide clipping**: `IPTV_DEV_SEED=1 "<Debug app>/Contents/MacOS/Lumio" -databaseName clip -guideClipTest YES`
  scrolls the guide and checks nothing is drawn outside it.
- **Playback probe**: `-databaseName probe -playProbe http://127.0.0.1:8098 -probeChannel 2 -probeSeconds 30`
  plays one harness channel and logs buffer, dropped frames and decoder every two seconds.
- **Soak**: run the Debug app with `-databaseName soak -smokeTest http://127.0.0.1:8097 -soakMinutes 240 -soakTiles 4`
  (start a harness on that port first).

## What's not done yet

Honest list of gaps against the brief:
- **Not verified against your real provider.** Everything was tested against the local harness.
  Please add your account and check sync, playback, the guide and VOD. Real panels have quirks the
  harness doesn't imitate.
- **Picture in Picture works only with AVPlayer (HLS).** mpv can't hand its frames to the system PiP
  window. The PiP button only appears when the stream is playing with AVPlayer.
- **No automatic display refresh-rate switching.** macOS doesn't let apps change display modes the
  way Android TV does. Diagnostics show stream fps next to the display rate.
- **4-tile multiview memory creeps up** by about 2 MB a minute during long sessions (about 120 MB
  an hour). Single-channel playback stays flat. Not investigated yet.
- **Movies and series aren't merged across providers** (live channels are).
- **No automatic "next episode"** when an episode ends.
- **Keychain prompts after rebuilding**: unsigned (ad-hoc) builds change signature on every build,
  so macOS asks again for Keychain access. Set your free Personal Team in `Config/Local.xcconfig`
  (see above) and the prompts stop.
- **Catch-up, timeshift, recording, M3U/Stalker and cloud sync** are out of scope for v1. The data
  model (`tvArchive`, `SourceProvider`, `SyncProvider`) is ready for them.
- **New users see a macOS warning the first time.** Releases aren't signed with a paid Apple
  Developer ID, so the first launch needs System Settings → Privacy & Security → Open Anyway
  (updates after that install without it). See
  [Publishing and updates](#publishing-and-updates) for signing with a Developer ID.
- **CI runs by hand only.** GitHub's Mac runners use an older Xcode than this project; see the
  CI paragraph under [Publishing and updates](#publishing-and-updates).

## Recents, Favorites, Regions and search

- **Recents** is the first page in the sidebar and the one the app opens on. It shows the channels
  you've watched as a guide, newest at the top, with the live preview and programme details above.
  Right-click a channel to remove it, add it to Favorites, or clear the whole list.
- **Favorites** shows your favorite channels the same way. **Drag a channel up or down** in the
  channel column to reorder (an open-hand cursor shows where you can drag), or right-click for
  Move to Top, Move to Bottom and Remove. The Movies and Series tabs at the top list favorite
  movies and series.
- **Movies and Series** start with a **Recently Watched** row (it replaces Continue Watching).
  A movie or episode you're partway through resumes when clicked; anything else opens its page.
  For a series, the card shows the last episode you played. Right-click for Play from the
  Beginning, Show Details, Remove from Recently Watched, or Clear Recently Watched. Removing keeps
  your progress, so the detail page can still resume.
- **Live TV → Recently Watched** (the group) also has Remove from Recently Watched in its
  right-click menu.
- **Regions** (Settings → Regions): most providers start group names with a region, such as
  "UK | Sports", "US: News", "[FR] Cinéma" or "EX-YU ▎ Sport". The app recognises these and lists
  each region with how many live groups it has, plus a few example names. Switch a region off and
  its channels disappear from Live TV, the Guide and Search (Show All / Hide All are there for
  large lists). Click a region to switch single groups in it on or off.
  - **Live TV only.** Movies and Series always show every category; right-click one there to hide
    it (Settings → Hidden brings it back).
  - Favorites and Recents still show what you picked.
  - The switches also apply to groups your provider adds later.
  - Recognised: country codes and names, with or without a separator ("UK | Sports", "SWEDEN HD &
    HEVC"), provider favourites like EN, AR, LATAM and EX-YU, and any other short code a provider
    uses as a prefix ("BEE| BEIN SPORTS" becomes a "BEE" switch). Tags like "VIP |", "4K |",
    "KIDS |" or "NBA |" are never mistaken for a region. Groups with no region at all ("24/7 …",
    "Formula 1") are listed under **Other Groups**, with a switch of their own.
  - **Codes are read the way your provider uses them.** If a provider's "IS" groups are named
    "IS| ISRAEL VIP" and "IS| HEBREW", its IS means Israel, not Iceland. The same goes for "SK|
    SOUTH KOREA" (not Slovakia) or "KU| KURDISTAN". A code only changes meaning when the group
    names spell it out; a provider that mixes two countries under one code keeps the usual one.
  - **Nothing is left out.** Groups the app can't place in a region are listed under **Other
    Groups** at the bottom, with a switch of its own (it also covers unrecognised groups your
    provider adds later).
  - **Single groups.** Click a region to open it and see every group in it (Live TV, Movies and
    Series), each with its own checkbox. Use these when the matching gets something wrong: for
    example, turn the UK off but keep one group on. Switching the whole region on or off again
    resets its groups to match. The filter box finds regions and single groups by name.
  - Movies and Series are often labelled by **language** (EN = English, FR = French) rather than
    country, so keep English switched on if you hide everything except the US.
  - **Different spellings are combined.** Providers label the same region differently, so the app
    reads each provider's spelling and files it under one region. NA, USA, U.S. and AMERICAN all
    count as the US. GB, BRITISH and UNITED KINGDOM count as the UK. Three-letter and sports codes
    (GER, NED, KSA), native names (DEUTSCHLAND, ESPAÑA) and language names (FRENCH) work too.
    Each row says which spellings it covers and which providers use them ("Seen as NA, US · on
    Main, Backup").
  - **Your own merges.** Use a row's ⋯ menu to **Merge Into** another region, or **Split Off** a
    spelling into a region of its own. Merges apply to the whole region, so a new spelling of it
    later (say "CAN" after merging Canada into the US) follows. A split-off spelling starts
    shown or hidden like the region it left. **Undo My Merges** goes back to the built-in rules.
  - To try it with the harness, start it with `--region-prefixes`, and a second one with
    `--region-prefixes=alt` (it spells the same regions "GB:" and "NA -").
- **Search** groups results under each provider (in priority order) when you have more than one.
  Click the star next to a channel (or right-click it) to add it to Favorites.
  A channel carried by several providers is listed under the one the app prefers, with its
  "2 sources" badge.

## Changing accounts or servers

When a subscription ends, or the seller gives you a new login, **edit** the provider (Settings →
Providers → pencil) and enter the new username, password or server address. Don't remove it and
add it again: removing a provider deletes its favorites, recents and watch history.

- **New login or new address, same panel** (the usual case): nothing changes for the library. The
  provider's IDs for channels, movies and series belong to its panel, so they stay the same.
- **A different panel** (the seller moved you to another operator, or rebuilt theirs): everything
  gets new IDs, and old ones can be reused for other channels. At the next refresh the app
  compares the old and new lists and moves your favorites, recents, watch progress, renamed and
  hidden channels, custom groups, guide matches and hidden or renamed groups to the new IDs.
  - Matching uses the guide ID, the name without quality tags ("UK: BBC One HD" = "UK| BBC ONE
    FHD"), the region, and for movies the TMDB ID and year. Different regions never match.
  - Episodes are matched by season and episode number. The app fetches the episode lists of
    series you're watching straight after the refresh, so progress carries over.
  - When a match isn't certain, it's left alone, so nothing is linked to the wrong channel. If the
    old ID now belongs to a different channel, the entry is removed instead.
  - The log notes how many entries moved (Console.app, category `sync`).
- To try it: start a second harness with `--renumber` (same catalog, new IDs and name style), then
  run the smoke test with `-smokeTestMoved http://127.0.0.1:<port>`.

## Security

What protects your accounts and this Mac, and the audit of 2026-10-19:

- **Credentials** live only in the macOS Keychain (one item per provider). The database, settings,
  backups and logs never contain them; anything logged or shown (errors, the stream URL in Stream
  Info) passes through `CredentialRedactor` first. `Tools/check_secrets.py` checks the repository.
- **Sandbox**: the app runs in the App Sandbox with only outgoing network access and access to
  files you pick (backups). Release builds use the hardened runtime and don't allow debuggers to
  attach.
- **Network**: only your providers, the logo and poster hosts they list, and (if configured) GitHub
  for update checks. No analytics. Plain HTTP is allowed because most Xtream servers use it, so
  treat a provider's connection like any unencrypted website.
- **Untrusted provider data**:
  - Logo, poster and guide-icon links must be http or https, so a provider can't point the app at
    files on this Mac.
  - Images are capped at 15 MB, guide downloads at 2 GB, and uncompressed guides at 6 GB (cut off
    there), so a broken or hostile server can't exhaust memory or disk.
  - The XML parser never loads external entities. Custom user agents are stripped of line breaks
    before being sent, so they can't add extra HTTP headers.
  - Stream URLs are built by the app with every part escaped.
- **Updates** (see [Publishing and updates](#publishing-and-updates)):
  - The app only follows https links on github.com, and asks before downloading anything.
  - Each update archive is signed with a private key that stays in the developer's Keychain. The
    app has the public key built in and refuses any archive whose signature doesn't match, so an
    update can't be swapped on the way or on GitHub. Updates must also be the same app (bundle ID)
    and a newer version.
  - Installing is done by a small installer service inside the app
    (`Contents/XPCServices/LumioInstaller.xpc`), because the sandboxed app can't replace itself.
    It checks everything again on its own copy of the archive before swapping the app in one
    rename, and only the app it ships in can talk to it.
- **Known limits**: Xtream puts the username and password in stream URLs (that's the protocol), so
  anyone who can see your network traffic to a plain-HTTP provider can see them. Provider API
  responses are read whole into memory (a few hundred MB at most for huge catalogs).

## Publishing and updates

Lumio is published at [github.com/jacksonf-netizen/lumio](https://github.com/jacksonf-netizen/lumio)
(public). Lumio's own code is under the [MIT licence](LICENSE); the libraries bundled with the app
keep their own licences ([THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)). Friends install it from the Releases page, and their copies update
themselves from there.

**Publishing a new version**
1. Make your changes and test them (`Tools/install.sh` installs them for you).
2. In `project.yml`, bump `MARKETING_VERSION` (e.g. `0.1.0` → `0.2.0`; `0.1.1` for small fixes)
   and `CURRENT_PROJECT_VERSION` (+1).
3. In `CHANGELOG.md`, move what's under `## Unreleased` into a new `## 0.2.0 — <date>` section.
   Keep it friendly: it's the release notes, and the start of it is what Lumio shows in its
   "update available" message.
4. Commit, then run:
   ```bash
   Tools/Release/publish.sh
   ```
   It refuses to run with uncommitted changes, an existing tag or no changelog section. Then it
   runs the secrets check, builds and signs the release, tags `v0.2.0`, pushes, and creates the
   GitHub release with the `.dmg` (for new installs), the `.zip` and `.zip.sig` (for updates) and
   checksums. Copies of Lumio offer the update the next time they open.

**The signing key.** Updates are signed with an Ed25519 key made by
`swift Tools/Release/sign_update.swift generate`. The private half is in your login Keychain
(item "Lumio update signing key") and never in the repository; the public half is
`UPDATE_PUBLIC_KEY` in `project.yml`, built into every copy of the app.
- **Back it up.** In Keychain Access, find "Lumio update signing key", show the password and save
  it in your password manager. Without it you can't publish updates that existing copies accept,
  and everyone would have to download the next version by hand.
- On a new Mac, add the item back with Keychain Access (same name, account `release`).
- `make_release.sh` refuses to sign if the Keychain key doesn't match `UPDATE_PUBLIC_KEY`.

**Update checks in the app**
- On each launch (a few seconds in), the app asks `api.github.com` for the latest release:
  one request, with nothing about you or your providers. Settings → About has the switch and
  **Check Now**; the app menu has **Check for Updates…**.
- When there's a newer version: **Install and Relaunch**, **Later** (asks again next launch) or
  **Skip This Version**. Pre-releases and drafts are ignored.
- Installing shows a progress window, checks the signature, has the installer service swap the
  app, and reopens it. If anything fails, the app is left as it was and you're offered the
  release page instead.
- If Lumio runs from somewhere it can't replace itself (straight from the disk image or Downloads,
  or a folder the account can't write to), it says so and offers the download instead.
- Debug builds don't check unless run with `-checkUpdatesAtLaunch YES`. To try the whole install
  path locally, serve `build/release` (`python3 -m http.server 8123` in that folder) and run a
  Debug copy built with `MARKETING_VERSION=0.0.9` with `-updateTestVersion 0.1.0
  -updateTestArchive http://127.0.0.1:8123/Lumio-0.1.0.zip -updateTestSignature
  http://127.0.0.1:8123/Lumio-0.1.0.zip.sig`. Use a copy outside Applications, since it
  replaces itself.

**Signing for other Macs without the warning.** Without a paid Apple Developer account the app is
ad-hoc signed, so new users click Open Anyway once (updates don't need it). With one, set
`DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"` and `NOTARY_PROFILE=<profile>`
when running the scripts; the comments at the top of `make_release.sh` show how to create the
profile.

**Before every push.** `Tools/Release/publish.sh` runs the secrets check for you. To run it before
every commit too:
```bash
printf '#!/bin/sh\npython3 Tools/check_secrets.py\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```
It looks through every file git would publish for your providers' addresses (read from the app's
database), anything in `LocalSecrets.json`, and keys or tokens. Generated and private files are
git-ignored: `build/`, the `.xcodeproj`, `LocalSecrets.json` and `Config/Local.xcconfig`.

**CI.** `.github/workflows/ci.yml` runs the secrets check, the unit tests and a Release build.
It's manual for now (GitHub → Actions → CI → Run workflow): GitHub's macOS runners only had Xcode
26.6 when it was first tried, and that compiler crashes on this code (Xcode 27 is needed). The file
shows how to turn the automatic runs back on once they have Xcode 27. Run the tests locally before
publishing (`swift test --package-path Packages/IPTVKit`).

## Phase 7 notes (search, backup, polish)

**What works**
- **Search** (sidebar): one box for channels, programmes on now or later (a LIVE badge with a Watch
  button), movies and series. It uses SQLite full-text search, matching word prefixes and ignoring
  case and accents ("sky spo" finds Sky Sports, "tele cafe" finds Télé Café). Renamed channels
  are found by their new names.
- **Favorites** (sidebar): favorite channels, movies and series in one place.
- **Settings → Backup**: export and import favorites, channel layout (hidden, renamed, reordered),
  custom groups, guide matches, watch history and settings as JSON. Usernames and passwords are
  never included. On a new Mac, add the same providers first, then import; providers are matched
  by server URL.
- **Faster failover**: if a provider refuses a stream (401, 403, 404 or connection limit) and
  another provider has the channel, the player switches straight there instead of trying that
  provider's other formats first.
- **Launch-speed fix**: replaced SwiftUI's `ContentUnavailableView`, which cost about 1.3 s on
  first use on this macOS version (found by bisecting).
- **Docs**: [core-api.md](Docs/core-api.md), [schema.md](Docs/schema.md) and
  [reconnect-state-machine.md](Docs/reconnect-state-machine.md).

## Phase 5 notes (Movies and Series)

**What works**
- **Movies** and **Series** homes, Netflix-style:
  - **Continue Watching** cards with progress and time left.
  - **Recently Added**.
  - Up to 8 category shelves with **See All**, then every category as a tile.
  - Search in the toolbar and a provider filter.
- **Category grids** sorted by provider order or recently added.
- **Movie page**: artwork, year, runtime, genre, rating, provider, plot, director and cast (fetched
  from the provider and cached), plus **Play / Resume** with a "Resume from 12:34 / Start from the
  Beginning" prompt, **Start Over**, favorite, and mark watched/unwatched.
- **Series page**: a season picker and episode list with thumbnails, runtime, plot, a progress bar
  and a ✓ for watched. **Play S1 E3 / Resume S2 E1** picks the right next episode. Right-click an
  episode to mark it watched.
- **Progress** is saved every 10 s and when playback stops. Reaching the end marks an item watched:
  the last 5%, or the last 3 minutes of anything 20 minutes or longer.
- **In the player**: a position bar with a draggable slider, ←/→ to seek 10 s back or 30 s forward,
  and Space to pause.

**Tested end to end** against the harness: a movie played, was seeked, closed, saved its position
and resumed from it; a series' episodes were fetched from the provider and one played. A bug found
this way is fixed: short videos were being marked watched halfway through.

**How to try it**: Movies → click a poster → Play. Close the player partway through: the movie
appears in Continue Watching, and Play offers to resume.

**Known issues / limits**
- Movies aren't merged across providers (each provider's copy is shown separately, with its name).
- There's no automatic "play next episode" when an episode ends; use Play on the series page.

## Phases 4 and 6 notes (Live TV, guide, player, multiview)

**What works**
- **Live TV**: groups (Favorites, Recently Watched, All Channels, your custom groups, then provider
  categories merged by name) → channel list (number, logo, name, now playing, progress, ★ for
  favorites, "2 sources" when a channel is on several providers) → **live preview** of the
  selected channel with now/next details. Double-click or Return plays full screen. The toolbar has
  **All Providers / one provider**, **Show Hidden**, and a **Preview** on/off switch.
  The channel list is a native virtualised table, so a provider with 50,000 channels scrolls as
  smoothly as one with 50.
- **Player**: full window, or full screen with **F**. Keys:
  - **↑/↓** or **Page Up/Down**: change channel (debounced while held)
  - **0–9**: jump to a channel number
  - **⌫** or **L**: last channel
  - **G**: guide overlay (G, Esc, its ✕ button or a click on the video closes it)
  - **D** or the **ⓘ** button: stream info (engine, codecs, buffer, dropped frames…); Esc or its ✕ closes it
  - **M**: multiview
  - **I**: show the channel banner
  - **Space**: pause
  - **Esc**: closes the top-most thing first (number entry, stream info, full screen), then the player

  The channel banner and movie title show the stream's resolution, frame rate and video format
  ("1080p · 50 fps · HEVC") once it starts playing.

  A banner in the top-left corner shows the channel, now/next and progress on every change. Moving the mouse shows the
  floating control bar: close, channel up/down, last channel, play/pause with a LIVE badge,
  audio/subtitle track menu, volume, guide, multiview and full screen (movies and episodes get a
  scrubber and ±10/30 s buttons instead). The player is always dark, whatever the system appearance.
  Channels without a logo show their initials on a rounded tile, everywhere logos appear. Media keys (play/pause,
  next/previous) work too. Menu bar: **Playback** (⌘↑ / ⌘↓ / ⌘⌫ and more) and **Window → Guide**
  (⌥⌘G) and **Player** (⌥⌘P), so the guide and the player can each have their own window.
- **Guide**: a full EPG grid with channels down the side and time across the top, a red **now
  line**, **Now** (back to the current time), a group picker, the live preview and programme details.
  Arrow keys move the selection; double-click or Return on a current programme plays it. It reads
  only the visible channels and time window, in day-sized blocks.
- **Channel management** (right-click a channel): favorite, rename, hide/unhide, add to a custom
  group, **Match Guide…** (pick a guide channel from any provider), **Sources** (unlink a provider's
  copy, or merge another channel in), and **Player Engine** (lock a channel to mpv or AVPlayer).
  Drag to reorder channels and groups. Right-click a group to rename or hide it, or delete a custom
  group. Each provider's **guide time offset** and **user-agent override** are in Providers → Edit.
- **Multiview** (**M** in the player, its grid button, or Playback → Multiview ⌥⌘M): it takes
  over the window like the player, starting with the channel you were watching. **Esc** (or the
  back button) returns to the full-window player on the tile you're hearing; **1–4** pick whose
  sound you hear; **F** is full screen; × closes it and stops every tile. 2, 3 or 4 tiles. Tiles are assigned across
  providers automatically, so capacity is the sum of every provider's free connections. Each tile
  shows its provider; click the badge to pin a different one. Click a tile to move audio focus to
  it, and double-click to watch it full screen. When nothing is free you get a clear warning
  instead of a silent failure.
- **Settings → Playback / Guide**: default engine, live format, buffer preset, stall timeout,
  user-agent, refresh intervals and days of guide to keep.

**Measured** (this Mac, Release build, a library with 300 channels):
- Launch to usable window: **0.57–0.60 s** (about 1.0 s on the very first launch after a fresh build).
- Guide with **1,500 channels × 8 days (576,000 programmes)**: frame draw median 0.5 ms, p95 9 ms
  (Debug build); the "All Channels" list loads in 168 ms; now/next for 60 rows takes 76 ms.
- First frame after pressing Watch: 1.8 s on the harness. Zapping 5 channels quickly opened one
  stream; the harness saw exactly 1 connection.
- **End-to-end smoke test** against two harness providers (A: 2 connections, B: 1):
  - Three multiview tiles split 2 on A and 1 on B.
  - A fourth tile showed the warning.
  - When A started returning 404 mid-stream, the player **failed over to B by itself** and
    showed "Now playing from Harness B".
  - No leaked connections afterwards.
  - Double-clicking a tile while every connection is in use goes back to the full-window player
    in about 2 s. All tiles close before the player opens its stream, and the harness refuses
    nothing (it now counts refusals in `/control/state`).

**How to try it**
1. Start one or two harnesses (see `Tools/StreamHarness/scenarios.md`) or use your real provider.
2. Live TV: click a channel (the preview plays), press Return to go full screen, try ↑/↓, numbers,
   L, G, D, M.
3. Guide: pick a day, click a programme, double-click a current one.
4. Multiview: while a channel plays, press M; add channels to tiles, click to move audio, try the
   provider badge, then press Esc to go back.

**Known issues / limits**
- Failover after a provider starts refusing a stream takes about 10 s. It first tries that
  provider's other format and AVPlayer before moving on; this could be tuned to skip straight to
  another provider on a 404.
- Picture in Picture isn't implemented yet (it will be AVPlayer-only).
- The guide shows logos once they've downloaded; there's no placeholder artwork.

## Phase 3 notes

**What works**
- **Two engines behind one `PlaybackEngine` protocol.** mpv (via MPVKit, rendering through
  Metal/MoltenVK, VideoToolbox hardware decoding) handles raw MPEG-TS, HEVC, AC-3 and E-AC-3.
  AVPlayer handles HLS and MP4 and is the fallback. The UI only ever talks to the protocol.
- **The reconnect state machine** (`PlaybackController`), documented step by step in
  [Docs/reconnect-state-machine.md](Docs/reconnect-state-machine.md):
  - A stall watchdog reconnects after 8 s without progress and shows a small "Reconnecting…" pill,
    never an error screen.
  - Exponential backoff with jitter, capped at 15 s.
  - A fallback ladder: the other format (`.ts` ↔ `.m3u8`), then the other engine, then the same
    channel on another provider, with a brief "Switching to…" notice. What worked is remembered
    per channel.
  - Network loss waits without burning retries, and sleep releases the connection then resumes on
    wake.
  - Zapping is debounced, and the old stream is always closed before the next opens.
  - Clear messages for 401, 403, 404, "max connections" (456/458/509), 5xx, timeouts and
    unsupported formats.
- **The preview gives way.** When full-screen or a multiview tile needs the preview's connection, the
  preview stops first, so a single-connection account never sees two streams.
- **A diagnostics overlay** shows the engine, format, provider, codecs, resolution, fps, decoder,
  bitrate, buffer, dropped frames, display refresh, reconnect count and the stream URL with
  credentials masked.
- **The stream harness** (`Tools/StreamHarness/harness.py`) is a fake Xtream provider, using ffmpeg,
  that can stall, drop, throttle, return any HTTP status or enforce a connection limit. Like a real
  server, it runs one encoder per channel shared by every viewer and sends new viewers the last
  4 seconds first, so the player starts with a buffer. See
  [Tools/StreamHarness/scenarios.md](Tools/StreamHarness/scenarios.md).

**Measured on this Mac** (M-series, harness on localhost):
- First frame: 1.06–1.78 s for H.264 720p, HEVC 1080p/AC-3 and H.264 50 fps/E-AC-3.
- Four mpv players at once: all on VideoToolbox, 0 dropped frames over 20 s, about 300 MB total.
- Rendering decision: mpv's `gpu-next` on Vulkan/MoltenVK into a `CAMetalLayer` works for 4
  simultaneous tiles, so the OpenGL fallback isn't needed.

**Tests:** 24 state-machine tests with a fake engine and a controllable clock: stall detection,
backoff bounds, ladder order, 404 skip, cross-provider failover, no-slot reporting, open timeout,
zapping storms, close-before-open, network loss, sleep/wake, preview preemption, fresh budget after
a long stall, VOD end, and a randomised chaos run that checks connections never leak or overbook.
There are also 4 real-engine tests against the harness (they're skipped if it isn't running).

**How to try it**
1. Start the harness: `python3 Tools/StreamHarness/harness.py --port 8088`.
2. Run the app and add a provider `http://127.0.0.1:8088` with username/password `test`/`test`.
3. Play channels from Live TV (phase 4), and use the scenarios in `scenarios.md` to break things.

**Known issues / limits**
- Picture in Picture isn't available for mpv; it will be offered for AVPlayer only.
- Automatic display refresh-rate switching isn't something macOS lets apps do the way Android TV
  does. Diagnostics show stream fps next to the display rate instead.
- Some providers report "max connections reached" as a plain 403. That 403 makes the player try
  the next fallback, so with a second provider it fails over; with one provider it fails with the
  403 message.

## Phase 2 notes

**What works**
- **Xtream client** for `player_api.php`: account info, live/VOD/series categories and lists,
  `get_vod_info`, `get_series_info`, `get_short_epg`, plus `xmltv.php`. Decoding is defensive:
  numbers sent as strings, nulls, `[]` instead of objects, numbered-object lists, HTML error pages
  and empty bodies are all handled. Tests use messy fixtures in `Tests/IPTVCoreTests/Fixtures/xtream`.
- **Specific error messages** for bad credentials, expired or disabled accounts, 403, 404, 429,
  5xx, "max connections", timeouts, being offline, and unreachable hosts. Credentials are masked in
  every message and log line.
- **Background sync** per provider: the account is checked first, then channels, movies, series,
  channel matching, and finally the guide. Writes only touch rows that actually changed, so the
  UI never sees a half-empty catalog. One failing part (e.g. movies) doesn't stop the others.
  At launch, stale providers refresh in the background (default every 12 h; checked every 30 min).
- **Guide import** streams gzip or plain XMLTV from disk, fixes bare `&`, HTML entities and
  control characters on the way, keeps a window of 1 day back to 7 days ahead, stores only
  channels someone actually carries, and removes programmes the provider dropped. Measured here:
  700,000 programmes (~150 MB of XML) in 44 s, with peak memory growth of 13 MB. A damaged file
  imports what's readable and never deletes existing data.
- **ConnectionManager** counts open streams per provider against `max_connections`. The preview
  pane gives up its slot automatically when the main player or a multiview tile needs it.
- **Channel matching** across providers by EPG id, then by normalised name ("UK: BBC One HD" =
  "BBC 1"), keeping "+1" channels separate, never putting two channels of one provider in a group,
  and pairing HD with HD and SD with SD. Manual link/unlink overrides are stored.
- **Tile assignment** for multiview: an exhaustive search, so 4 tiles over 2 accounts × 2
  connections always fits when it's possible at all.
- **Providers screen** shows account status, expiry, connections in use / max, item counts, last
  refresh and last error, and has Refresh, Edit and Refresh All (⇧⌘R). A small indicator in the
  toolbar shows background activity.

**How to try it**
1. `xcodegen`, then ⌘R.
2. Settings → Add Provider… with your real account. Within seconds the row shows Active, expiry,
   connections, and channel/movie/series counts. The guide follows; it's the slowest part.
3. Or copy `LocalSecrets.example.json` to `LocalSecrets.json`, fill it in, and use
   **Debug → Import Providers from LocalSecrets.json…**. This menu only exists in Debug builds.
4. Quit and relaunch: counts appear instantly from the cache, and nothing re-downloads unless it's stale.
5. Live TV / Guide / Movies / Series placeholders show how much has synced.
6. Run the tests with ⌘U. To run the big guide benchmark from the terminal:

```bash
cd Packages/IPTVKit && IPTV_PERF_PROGRAMMES=700000 swift test --filter largeGuideImportsWithFlatMemory
```

**Known issues / limits**
- Not yet verified against your real provider (I don't have credentials). Please try step 2 and
  tell me what the row shows.
- Manual EPG matching and channel link/unlink are stored and applied, but their UI comes in phase 4.
- If a guide file is malformed partway through, everything after the fault is lost for that
  refresh. That's an XMLParser limitation; the importer keeps what it read and keeps the old data.

## Phase 1 notes

**What works**
- The app launches to a sidebar (Live TV, Guide, Movies, Series, Favorites, Search, Multiview,
  Settings). Sections not built yet show which phase brings them.
- With no providers, content sections show an **Add Provider…** button that opens Settings.
- Settings → Providers: add (name, server URL, username, password), remove (with confirmation),
  enable/disable, and drag to reorder priority. Server URLs are cleaned up: a missing `http://` is
  added, and a pasted `player_api.php?...` is stripped. URLs with credentials in them are rejected.
- Passwords go only to the Keychain. A test scans every database column to prove it.
- Removing a provider deletes everything it owns. A test seeds every table and checks the cascade.
- Schema v1 is complete for all phases, including full-text search tables.

**How to try it**
1. `xcodegen`, then open the project and press ⌘R.
2. Sidebar → Settings → **Add Provider…**. Any values work. Nothing is contacted yet.
3. Open Keychain Access and search "iptvstreamer" to see the stored item.
4. Remove the provider and check that the Keychain item is gone.
5. Press ⌘U to run the 24 tests.

**Known issues / limits**
- Provider status (expiry, connections, last refresh) arrives in phase 2.
- There's no editing of an existing provider's URL or credentials in the UI yet. Remove it and
  add it again.
- No app icon yet.
