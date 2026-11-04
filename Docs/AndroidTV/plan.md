# Lumio for Android TV: plan

Status: proposal, not started. Written 2026-11-03.

The goal is an Android TV / Google TV version of Lumio that runs well on cheap
streaming sticks, shares its logic with the Mac app so one fix reaches both, and installs by
typing a code into the Downloader app.

## Decisions this plan rests on

1. **One shared core, in Swift.** `IPTVCore` (and `LumioUpdate`) compile for Android with the
   official Swift SDK for Android (first official release with Swift 6.3, March 2026). Android
   gets the same Xtream client, sync, guide import, database, server-link failover, regions,
   channel matching, connection slots and reconnect state machine as the Mac, and the same
   tests run on both.
2. **Native screens and player per platform.** The Mac keeps SwiftUI and mpv. Android TV gets
   Kotlin screens built for the remote's arrow keys and Media3 (ExoPlayer), which uses the
   device's hardware decoders. Nothing about the Mac app's look or behaviour changes.
3. **A thin bridge.** Kotlin talks to the core through JNI (JSON requests; swift-java was the first plan, see "The bridge"). The bridge exposes a
   small set of coarse calls ("give me this screenful of guide rows"), never one call per cell
   or per frame.
4. **A spike first, with a go/no-go.** Before any real work, a throwaway build measures app size,
   start-up time, memory and guide import speed on a real low-end device. If Swift on Android
   misses the targets badly, the fallback is a separate Kotlin core (see "Fallback").
5. **One repository, one version number, one GitHub release per version** carrying both the Mac
   and the Android builds.
6. **Google TV / Android TV first.** Fire TV isn't a target. Fire OS 7+ devices may well run the
   app, but they aren't tested or designed for, and Fire OS 6 devices can't install it.

## Target devices

Chosen by Jackson (2026-11-03): the **onn. Google TV streaming devices from 2023**.

| | onn. Full HD Streaming Device (2023) | onn. 4K Streaming Box (2023) |
|---|---|---|
| Role | **minimum**: every budget below is measured here | the common case |
| Chip | Amlogic S805X2 (quad-core Cortex-A35/A53, Mali-G31 MP2) | Amlogic S905X4 |
| RAM | 1.5 GB | 2 GB |
| System | Google TV, Android 12, **32-bit** | Google TV, Android 12 |
| Output | 1080p | 4K, HDR |

The 4K box's details still need checking on the device itself (`adb shell getprop`): whether its
system is 32-bit and which Android version it has now. Specs reviewed: androidpctv.com reviews of
both devices, Walmart listings.

Consequences:

- Minimum Android version: **Android 9 (API 28)**, the Swift SDK's baseline. Both onn devices run
  Android 12, so this leaves room for other Google TV and Android TV devices.
- The app ships **both 32-bit ARM (armeabi-v7a) and 64-bit ARM (arm64-v8a)** in one APK
  (decided 2026-11-04): 32-bit for the HD stick's 32-bit system, 64-bit for newer and 64-bit-only
  devices. The libraries are stored compressed, so the APK carries both at about half their size
  and the device unpacks only its own.
  The Swift SDK builds armv7, aarch64 and x86_64.
- Video must decode in hardware. Software decoding (mpv, VLC) is too slow for HD on these chips
  and would add 20–60 MB, so it isn't used on Android.
- With 1.5 GB shared with the system and the launcher, the app gets a few hundred MB at most
  before Android starts closing it in the background.

### Budgets (pass/fail for the spike and every release after it)

| | Target | Hard limit |
|---|---|---|
| APK size (32- and 64-bit ARM, compressed libraries) | ≤ 35 MB | 50 MB |
| Installed size (APK plus the unpacked library) | ≤ 80 MB | 120 MB |
| Cold start to cached Live TV list, onn HD stick | ≤ 2 s | 3 s |
| Memory while browsing (PSS) | ≤ 150 MB | 200 MB |
| Memory while playing HD | ≤ 200 MB | 250 MB |
| Channel change to first frame (local harness, onn HD stick) | ≤ 1.5 s | 2.5 s |
| Guide import, 50 MB XMLTV, onn HD stick | ≤ 60 s | 120 s |
| Guide scroll | no dropped frames visible at 60 Hz | |

## Repository layout

Everything stays in the one repository (`jacksonf-netizen/lumio`). Every file sits under a folder
named after the app that uses it, or `Shared/` / `Tools/` when both do. This layout is already in
place (reorganised 2026-11-03); the Android parts get filled in by the phases below.

```
LUMIO/
├── README.md, CHANGELOG.md, LICENSE, THIRD-PARTY-NOTICES.md
├── Shared/                    used by both apps
│   └── LumioCore/             Swift package: IPTVCore, LumioUpdate, their tests and fixtures
│       └── Sources/IPTVBridge/    (phase 2) the facade the Android app calls
├── Mac/                       the Mac app only
│   ├── project.yml            XcodeGen spec (holds the version number today)
│   ├── App/                   app shell (IPTVMac) and update installer (LumioInstaller)
│   ├── LumioMac/              Swift package: IPTVUI (SwiftUI), IPTVPlayback (mpv, AVPlayer)
│   ├── Config/                code signing
│   ├── Tools/                 install.sh, app icon, release build and signing
│   └── build/                 build output (not committed)
├── AndroidTV/                 the Android TV app only (Gradle project, from phase 0)
│   ├── app/                   screens, ExoPlayer engine, platform services
│   ├── core-bridge/           Kotlin side of the bridge + the compiled shared core (.so files)
│   ├── baselineprofile/       start-up and scroll profiles for low-end devices
│   ├── Tools/                 Android build, signing and device scripts
│   └── build/                 build output (not committed)
├── Tools/                     used by both apps
│   ├── StreamHarness/         fake providers for testing (the Android emulator reaches them too)
│   ├── Release/               publish.sh (publishes both apps), sign_update.swift
│   └── check_secrets.py
└── Docs/
    ├── Shared/                core API, database schema, reconnect state machine
    ├── Mac/                   Mac development guide
    └── AndroidTV/             this plan; later the Android development guide
```

Rules that keep it this way:

- A new file goes under the folder of the app that uses it. If both apps need it, it goes in
  `Shared/` (code) or `Tools/` (scripts), never in `Mac/` or `AndroidTV/`.
- Each top folder has a short README saying what's in it.
- The version number lives in a top-level `version.properties` (since phase 1). Both the Xcode
  project and Gradle read it, so neither app owns it.

## How the shared core becomes portable

A file-by-file audit of `IPTVCore` found the following Apple-only pieces. Each gets a small
seam; behaviour on the Mac stays identical, and the Mac tests and smoke test must pass after
every step.

| Piece | Today | On Android |
|---|---|---|
| Saved logins (`Security/SecretStore.swift`) | Keychain | `SecretStore` implemented in Kotlin: an AES key held in the Android Keystore encrypts a small file in app-private storage. Passed into the core through the bridge. |
| Logging (`Support/Log.swift`, `os.Logger`) | unified log | `#if canImport(os)`; on Android, `__android_log_write` (logcat). The `CredentialRedactor` rule stays: no credentials in any log. |
| Update signatures (`LumioUpdate`, CryptoKit) | CryptoKit Ed25519 | `swift-crypto` (Apple's open-source CryptoKit API) on Android, `#if canImport(CryptoKit)`. Same public key, same signature format. |
| Networking (`Xtream/HTTPTransport.swift`, `URLSession`) | URLSession | FoundationNetworking (curl-based) first. The spike checks plain HTTP, HTTPS certificate checks against Android's CA store, redirects, gzip and a 100 MB+ download. If it misbehaves, `HTTPTransport` (already a protocol) gets an implementation backed by Android's `HttpURLConnection`, with downloads written straight to a file. |
| XML (`EPG/XMLTVParser.swift`, `XMLParser`) | Foundation | FoundationXML (libxml2). The spike measures speed on the onn HD stick. |
| zlib (`linkedLibrary("z")`) | system | NDK's libz. |
| Database (GRDB 7.11.1) | system SQLite | GRDB supports Android since 7.10. The spike checks the SQLite it uses has **FTS5** (search depends on it) and WAL mode. |
| Network / sleep events (`SystemEvents`) | NWPathMonitor, NSWorkspace | Kotlin: `ConnectivityManager` callbacks and activity lifecycle, forwarded to the core. |
| Clock (`AppClock`), `Observation` | Foundation / stdlib | expected to work unchanged; verified in phase 1. |

`Shared/LumioCore/Package.swift` gains Android as a platform (for `IPTVCore`, `LumioUpdate` and
the new `IPTVBridge`). `Mac/LumioMac` (`IPTVPlayback`, `IPTVUI`) stays macOS only.

## The bridge

Kotlin never sees GRDB, actors or Swift concurrency. It sees one facade, `LumioCore`, with:

- **Coarse calls returning plain values**: providers, add/edit/remove provider, refresh,
  channel groups, a page of channels, a guide window (rows × time range, one call per visible
  screen), VOD shelves, details, search results, favorites, recents, settings.
- **Change notifications**: the core already observes the database (GRDB `ValueObservation`).
  The bridge turns each observed query into a Kotlin callback carrying the new rows, so screens
  update when a refresh finishes, like on the Mac.
- **Playback**: `PlaybackController` (Swift) keeps owning the reconnect and fallback logic. The
  Kotlin ExoPlayer engine implements `PlaybackEngine` through the bridge: the core calls
  `open(url, options)` / `stop()`; the engine reports state changes and once-a-second metrics
  back. That's a few calls per second at most.
- **Platform services passed in at start-up**: `SecretStore`, `SystemEvents`, the clock, the
  database file path, the cache directory.

Data crosses as compact JSON (decided 2026-11-04, in place of swift-java). swift-java was at 0.7
and still changing every few weeks (its async support was being fixed release by release), and
its generated wrappers would cost one JNI crossing per property: thousands for a channel list,
where JSON is one. Nothing crosses per frame, so JSON's cost doesn't matter. swift-java can be
reconsidered once it reaches 1.0.

How it's built (phase 2):

- `Shared/LumioCore/Sources/IPTVBridge`: `BridgeCore` takes `{"method", "params"}` requests and
  answers `{"result"}` or `{"error"}` (a message fit to show, credentials removed), and pushes
  events (`providers`, `live`, `guide`, `sync`). Its types (`BridgeModels.swift`) are the bridge's
  own, so the core can change without the app noticing. Platform-neutral: its tests run on the Mac
  and on Android.
- `AndroidTV/core-bridge/Sources/CJNI/cjni.c`: the JNI entry points and callbacks, in C. Text
  crosses as UTF-8 byte arrays, because JNI's string functions use "modified UTF-8", which breaks
  on emoji (common in channel names). It also hooks Swift's main queue into the UI thread's
  looper, so core code that runs on the main queue or the main actor works as on the Mac.
- `AndroidTV/app/.../core/LumioCore.kt` and `BridgeModels.kt`: one suspend function per request
  and one data class per type. Both sides' tests read the same fixtures
  (`Shared/LumioCore/Tests/IPTVBridgeTests/Fixtures`), so a renamed field fails a test.
- Logins: the core's `SecretStore` calls back into Kotlin's `LoginVault` (AES-GCM, key in the
  Android Keystore, files in the no-backup folder).
- Threading: Kotlin calls run on `Dispatchers.IO` and block that thread until the core answers.

Rule for keeping two apps in step: **if it isn't drawing pixels or touching the platform, it
belongs in `IPTVCore`.** No business logic in Kotlin. A Kotlin screen that needs a rule (sorting,
region hiding, what counts as "now") asks the core.

## The Android TV app

### Stack

- Kotlin, Gradle, minSdk 28, targetSdk the current one Google Play requires.
- Screens: Compose for TV (`androidx.tv`), with baseline profiles and R8. The guide grid is the
  one screen most likely to stutter on a weak GPU. If the spike shows dropped frames, the grid
  becomes a single custom `View` that draws visible cells on a canvas, the same approach as the
  Mac guide.
- Player: Media3 ExoPlayer (MPEG-TS and HLS), hardware decoding through MediaCodec, buffer
  sizes from the same `BufferPreset` settings as the Mac, smaller defaults on devices reporting
  low RAM.
- Images: a small loader of our own (disk cache, decode at display size, memory cap), mirroring
  the Mac's `ImageCache`. Coil is the fallback if ours costs too much time; it's a dependency,
  so it needs approval.
- Audio: many cheap sticks can't decode AC-3 / E-AC-3 themselves. First choice is passthrough
  to the TV or soundbar. If a test device plays silence on AC-3 channels, the Media3 FFmpeg audio
  extension (LGPL, a few MB) is the option, decided with Jackson because of size and licence.

### Features in the first Android release

Same behaviour as the Mac, built for a remote:

- Providers: add with every server link, logins in the Keystore, refresh, status, links
  up/down, automatic failover.
- Live TV: groups, channel list with logos and now/next, region and category hiding.
- Player: full screen, channel up/down on the remote, number entry, info banner, back to the
  previous channel, reconnect and format/provider fallback ("Reconnecting…").
- Guide grid with a now line, Favorites, Recents.
- Movies and Series: shelves, details, seasons/episodes, resume.
- Search (on-screen keyboard; voice search later).
- Settings: providers, sidebar sections, regions and hidden categories, refresh schedule,
  playback basics, About with updates and acknowledgements.

- Multiview (phase 5b): 2 to 4 tiles, each its own ExoPlayer with a hardware decoder, the same
  tile assignment across providers as the Mac. How many tiles a device gets comes from what its
  decoder reports (`MediaCodecInfo` instance limit and supported frame rates at each tile's size),
  not a fixed number; the onn HD stick may top out at 2, the 4K box should manage 4. Smaller
  buffers per tile, audio from the focused tile only.

Not on Android: extra windows, the AVPlayer engine, and backup import/export (Jackson,
2026-11-04: not needed on the TV).

### Security and privacy, same rules as the Mac

- Logins only in Keystore-protected storage. `android:allowBackup="false"`, so Google's cloud
  backup never copies them.
- Never log credentials (same `CredentialRedactor`).
- Network: the user's providers, their logo/poster hosts and GitHub (update checks). No
  analytics, no Google Play Services dependency, no Firebase.
- Plain HTTP is allowed (most Xtream panels use it) through a network security config, as the
  Mac allows it through ATS.
- Image URLs must be http(s), with the same size limits as the Mac.

## Installing and updating on a TV

### First install with Downloader

1. Every release attaches the Android app as **`Lumio-AndroidTV.apk`**. The name never contains
   the version, so this URL always serves the newest build:
   `https://github.com/jacksonf-netizen/lumio/releases/latest/download/Lumio-AndroidTV.apk`
2. A Downloader code is created once at go.aftvnews.com pointing **straight at that APK URL**
   (decided 2026-11-03). The code never needs to change. Creating it publishes the URL in
   AFTVnews's public list, which is fine because the repository is public. It's created after the
   first Android release exists; Jackson creates it, or approves Claude doing it then.
3. Instructions for friends (README and release notes): install **Downloader** from the Google
   Play Store on the TV. Allow it to install unknown apps (Settings → Apps → Security &
   restrictions → Unknown sources → Downloader). Open Downloader, type the code, and install.

### Updates inside the app

- Lumio for Android checks GitHub's latest release at launch, the same feed the Mac uses.
- It downloads `Lumio-AndroidTV.apk` and checks `Lumio-AndroidTV.apk.sig` with the same Ed25519
  key as the Mac (`LumioUpdate`, shared). An unsigned or tampered APK is refused before Android
  sees it.
- It hands the file to Android's `PackageInstaller`. Android shows its own install prompt, and
  the user presses Install. Needs the `REQUEST_INSTALL_PACKAGES` permission and, once,
  "install unknown apps" for Lumio itself.
- Android only accepts an update signed with the same APK signing key as the installed app.

### The APK signing key

- Created once (`keytool`), APK signature schemes v2 and v3. v3 allows a later key rotation.
- The keystore file and its passwords live in Jackson's macOS Keychain and one offline backup,
  never in the repository. `Tools/check_secrets.py` and `.gitignore` gain `*.jks`,
  `*.keystore` and `keystore.properties`.
- **If this key is lost, no installed copy can ever update again**: every user would have to
  uninstall (losing settings) and reinstall. The backup isn't optional.

## Releases: one version, both platforms

- `version.properties` (top level, from phase 1) is the single source of the version. Xcode reads
  it through an xcconfig; Gradle reads it as `versionName` and derives `versionCode` from it (e.g.
  0.2.0 → 2000), so the two apps can't drift.
- `Tools/Release/publish.sh` builds both: the Mac `.dmg`/`.zip`/`.zip.sig` through
  `Mac/Tools/Release/make_release.sh` as now, plus `Lumio-AndroidTV.apk` and `.apk.sig` through
  `AndroidTV/Tools/make_release.sh`, all in one `SHA256SUMS.txt`, all on one GitHub
  release. The Mac's update checker only looks at `.dmg`/`.zip` assets, so the APK doesn't
  confuse it (checked in phase 6).
- Every release carries both builds, even when only one platform changed, so "latest" always
  has both, and the existing rule (delete the previous release, keep its tag) keeps working.
- To avoid offering a pointless update, each release's notes carry a hidden marker of which
  platforms changed (`<!-- platforms: mac, android -->`). Each app only prompts when its own
  platform is listed. The changelog gets "Mac:" / "Android TV:" prefixes where a line applies
  to one platform.
- Verification after publishing, extended for Android: checksums, `apksigner verify` with the
  expected certificate fingerprint, `versionName`/`versionCode` inside the APK, the `.sig`
  check, and a fresh install of the published APK on the emulator.

## How I'll work on both and keep them in step

### Branches

- `main` is always releasable for the Mac; `Tools/Release/publish.sh` releases from it.
- Android work (and any larger change) goes on a branch named after the phase or feature, for
  example `android/phase-2-app-shell`, pushed to GitHub with a pull request into `main`. CI runs on
  the pull request; it's squash-merged once the workflows it triggers pass, and the branch is
  deleted. Small Mac fixes can still go straight to `main`.
- A release in the middle of Android work is no problem: Android code merged into `main` doesn't
  change the Mac app, and the Mac tests prove it on every pull request.

### Every change

1. Logic change in `IPTVCore`, with a test. The test runs on macOS and on Android (CI).
2. Mac screens if affected, verified with the Mac smoke test.
3. Android screens if affected, verified with the Android smoke test on the Android TV emulator.
4. One changelog entry, with a platform prefix if it's one-sided.

A feature isn't done until both apps have it, or the changelog says on purpose that one
doesn't (for example backup import/export).

### Testing

- **Core tests on Android**: the same ~200 `IPTVCoreTests` cross-compiled and run on an Android
  emulator (x86_64 on CI, arm64 locally), so a Swift-on-Android difference shows up as a failing
  test, not a bug report.
- **Bridge tests**: Kotlin unit tests that call the real core through the bridge with fixture
  data.
- **Android smoke test**: an instrumented test (like the Mac's `-smokeTest`) that adds the
  Python harness as a provider (the emulator reaches the Mac at `10.0.2.2`), syncs, plays a
  channel, forces a stall and checks it reconnects, zaps, opens the guide and fails over between
  server links. It saves screenshots I review.
- **Real device**: the onn HD stick on Jackson's network with wireless debugging turned on (see
  "Testing from the Mac"). I install builds on it and measure start-up, memory, frame timing and
  channel-change time with `adb` and Perfetto before each release that touches screens or
  playback.

### Testing from the Mac

There are two ways, and both are needed.

**1. The Android TV emulator (most day-to-day testing).** Google's emulator runs a full Google TV
system in a window on the Mac. On Apple silicon it runs ARM system images natively, so it's fast.

- Set up once: the Android command-line tools, the emulator and a "Google TV" system image
  (arm64, Android 12 or later), as a virtual device sized 1080p.
- The Mac's arrow keys, Enter and Escape act as the remote's D-pad, OK and Back. The emulator
  also has an on-screen remote.
- The test servers in `Tools/StreamHarness` run on the Mac; the emulator reaches them at
  `http://10.0.2.2:<port>`.
- I drive it from the terminal: install builds (`adb install`), press remote buttons
  (`adb shell input keyevent`), take screenshots (`adb exec-out screencap -p`) and read logs
  (`adb logcat`). You can watch the emulator window while I do.
- Limits: the emulator is 64-bit and runs on a fast Mac, so it can't show how the app performs
  on the onn stick or test its 32-bit build. Video decoding also differs from the real chip.

**2. The onn device itself, controlled from the Mac (before every release).** Same `adb`
commands, over Wi-Fi.

- Set up once on the onn: Settings → System → About → click "Android TV OS build" 7 times to
  unlock Developer options. Then Settings → System → Developer options → turn on "USB debugging"
  and "Wireless debugging". Under Wireless debugging, "Pair device with pairing code" shows an
  address and a code.
- On the Mac: `adb pair <address> <code>`, then `adb connect <address>`. After that I can install
  builds, take screenshots and measure performance on the real device while it sits on the TV.
- This is where the budgets are checked, the 32-bit build gets tested, and real streams are tried
  (with your own provider; I don't use your login, you enter it on the TV).

### CI (GitHub Actions)

Three workflows, each running only when its part of the repository changes (set up 2026-11-04):

- `mac.yml` (macOS runner): shared core tests, Mac tests, Mac Release build. Runs when `Shared/`,
  `Mac/`, `Tools/`, `version.properties` or the notices change.
- `android.yml` (Linux runner, x86_64 emulator): builds SQLite and the core for Android, runs the
  core tests on the emulator, builds the APK for both ARM types and fails above the 50 MB size
  limit. Runs when `Shared/`, `AndroidTV/` or `version.properties` change. Kotlin unit tests and
  lint join it in phase 2.
- `secrets.yml` (Linux): `Tools/check_secrets.py` on every push and pull request.

A change to `Shared/` runs both app workflows, which is the point: the shared core must keep
working on both platforms.

### Tooling on this Mac (installed 2026-11-03, not app dependencies)

`source AndroidTV/Tools/env.sh` sets everything up in a terminal.

| Tool | Version | Where |
|---|---|---|
| Java (Homebrew `openjdk@21`) | 21.0.13 | `/opt/homebrew/opt/openjdk@21` |
| Android command-line tools | 16111833 | `~/Library/Android/sdk/cmdline-tools/latest` |
| Platform tools (`adb`) | 37.0.1 | `~/Library/Android/sdk/platform-tools` |
| Emulator | 37.2.13 | `~/Library/Android/sdk/emulator` |
| Android platform / build tools | 36 / 36.1.0 | `~/Library/Android/sdk` |
| Android NDK | r30 (30.0.16248370) | `~/Library/Android/sdk/ndk` |
| Google TV image | Android 12 (API 31), arm64 | emulator `Lumio_GoogleTV_12`, 1080p |
| Swift toolchain (open source) | 6.4.2 | `~/Library/Developer/Toolchains`, used only for Android builds |
| Swift SDK for Android | 6.4.2 | `~/Library/org.swift.swiftpm/swift-sdks` |

The Mac app keeps building with Xcode's own Swift. The Swift SDK for Android must match its
compiler exactly, so Android builds use the open-source 6.4.2 toolchain; updating one means
updating both.

Checked so far: a Swift program cross-compiled for 32-bit ARM (armv7) and 64-bit ARM (aarch64),
and the 64-bit one ran on the emulator. The emulator image is 64-bit only, so the 32-bit build can
only be run on the onn HD stick.

## Phases

Each phase ends with Mac tests + Mac smoke test still green, and a short report.

### Phase 0: spike and go/no-go

Test-build code, labelled "Phase 0" where it will be replaced.

- Install the tooling. Build `IPTVCore` for armv7 and aarch64 with the minimum changes needed to
  compile (stub secret store, logcat logging).
- Run the core test suite on the Android TV emulator; list what fails and why.
- A bare Android TV app: one screen that adds the harness as a provider, syncs, and lists
  channels through a hand-written bridge call, plus an ExoPlayer view playing one channel.
- Measure against the budgets: APK size (universal and per-ABI), cold start, memory, guide
  import of a 50 MB XMLTV, HTTPS download, FTS5 present, on the emulator and on the onn HD
  stick.
- Write up the results in this file and recommend go, go with changes, or fallback.

**Go/no-go is Jackson's decision on those numbers.**

#### Results so far (2026-11-03, Google TV emulator)

Done on the emulator; the onn HD stick measurements are still to come. The test build lives in
the real locations (`AndroidTV/app`, `AndroidTV/core-bridge`, `AndroidTV/Tools`), not on a branch;
its throwaway parts are labelled "Phase 0" in the code.

What works on Android, through the shared Swift core:

- The whole core compiles for 32-bit and 64-bit ARM. Changes needed in `Shared/LumioCore`: a
  logcat `Logger` (`Support/AndroidLogger.swift`), swift-crypto in place of CryptoKit, the Mac's
  installer and Keychain store behind `#if`, FoundationNetworking/FoundationXML imports, and one
  Mac-only URLSession setting. The Mac builds and passes its tests unchanged.
- 200 of the 201 core tests pass on Android (`AndroidTV/Tools/run_core_tests.sh`). The one real
  difference it found: a cut-off guide file wasn't detected on Android. Fixed for both platforms
  (the parser now counts unclosed elements). The other failure seen once is a timing test that
  allows 10 s and took 11.7 s on a loaded emulator.
- The test app signs in to the harness, syncs channels, movies, series and the guide, lists the
  channels, plays them with ExoPlayer (first frame 0.7–0.9 s, H.264 and HEVC), searches (FTS5
  results identical to the Mac) and checks for updates over HTTPS. HTTPS certificate checking
  works: expired, self-signed and wrong-host certificates are refused.
- Memory while playing HD: 59 MB (Android's PSS). Budget 200 MB.
- Large guide import (core test, debug build): 200,000 programmes in 82 s with 3 MB memory growth.
  Release-build timing on the onn still to measure.
- Start-up: the core is ready 0.07–0.8 s after the screen opens on later launches; the very first
  launch after installing took 3.6 s (database created, 37 MB library read for the first time).

Problems found and fixed:

- SQLite: Android gives apps none, so the build compiles the official amalgamation with FTS5
  (`AndroidTV/Tools/build_sqlite.sh`).
- HTTPS: the statically linked curl needs the SDK's OpenSSL linked in (`core-bridge/Package.swift`).
- Downloads crashed: Android apps have no TMPDIR, so Foundation wrote to `/data/local/tmp`. The core
  is now given the app's cache folder at start-up.
- Size: Swift's Foundation carries all of ICU's data (32 MB). `AndroidTV/Tools/build_icu_data.sh`
  keeps what Lumio uses (6.3 MB: core tables, time zones, root and English, word-break rules,
  Western character sets). The test app's ICU checks give identical answers with full and trimmed
  data. (ICU's own `icupkg` tool can't be used: it re-sorts items, which ICU 76 can't read.)

Size, per CPU type, after trimming: `liblumiocore.so` is 36–37 MB (about 14.5 MB compressed). What
it holds: Swift standard library and Foundation about 20 MB, ICU data 6.3 MB, GRDB 2 MB, Lumio's
core 1.5 MB, SQLite 1.3 MB, swift-crypto 1.6 MB, curl/OpenSSL/libxml2 about 2.5 MB. Size-optimised
compiling saves only 0.7 MB. APK options:

| APK | Download | Notes |
|---|---|---|
| Both CPU types, libraries uncompressed (Android's default) | 77 MB | too big to download comfortably |
| Both CPU types, libraries compressed | 31.3 MB (measured) | **chosen**; the device unpacks its own library (about 37 MB) |
| 32-bit ARM only, libraries compressed | about 17 MB | runs on both onn devices; not on 64-bit-only devices |

Further savings available: verify update signatures with the OpenSSL that's already linked instead
of swift-crypto (−1.6 MB per CPU type, and one dependency fewer), and trim ICU further.

Still to do for the decision: the same measurements on the onn HD stick (start-up, memory, guide
import in a release build, channel change, and the 32-bit build), and whether the onn 4K box is
32-bit (`adb shell getprop ro.product.cpu.abilist`).

Learned along the way:

- The first network request after installing took 6.7 s on the emulator; later ones about 10 ms.
  To recheck on the onn.
- A guide download now waits 5 s after the catalog requests (flood protection), which is most of a
  small provider's sync time.
- Unknown curl errors (including certificate failures) arrive as a generic error code; they should
  map to clear messages (phase 1).
- Gigabytes of new tools and build output make Spotlight index for a while, which slows the Mac's
  smoke test.

### Phase 1: portable core

- `Package.swift` with Android; the seams from the audit table; `swift-crypto` for Android.
- All core tests pass on Android in CI. Mac behaviour unchanged.

Done 2026-11-04:

- The seams and `swift-crypto` went in during phase 0.
- `version.properties` holds the version for both apps (`Mac/Config/Version.xcconfig` includes it;
  Gradle reads it as a properties file; comments use `//` because Xcode reads it too).
- Network failures that Swift's Android networking (curl) reports as "unknown" are read from
  curl's message and mapped like the Mac's (`XtreamError.fromTransportMessage`): certificate and
  connection problems are "couldn't connect", so an unreachable server link now triggers link
  failover on Android as it does on the Mac. Checked against real failures on the emulator.
- 203 of 203 core tests pass on the emulator.
- `.github/workflows/android.yml`: a Linux job that builds SQLite, runs the core tests on an
  x86_64 emulator, builds the core for both ARM types, builds the APK and fails above 50 MB. The
  Android scripts work on Linux as well as the Mac (`env.sh`). Not yet run on GitHub.

### Phase 2: bridge and app shell

- `IPTVBridge` facade, swift-java generation in the Gradle build, Keystore `SecretStore`,
  `SystemEvents` from Kotlin.
- Android app: navigation for the remote, Settings → Providers (add with links, refresh,
  status), Live TV groups and channel list from the shared core, background refresh schedule.

Done 2026-11-04 (branch `android/phase-2-app-shell`):

- The bridge as described in "The bridge" (JSON in place of swift-java).
- Shared wiring: `AppEnvironment` (the services and the background schedule) and the provider
  actions (add, save, remove, switch off, reorder, refresh) moved from the Mac app into the core
  (`Shared/LumioCore/Sources/IPTVCore/App`), so both apps follow the same rules. The Mac app uses
  them unchanged; its tests and smoke test pass.
- The Android app (Compose for TV): a sidebar, Settings → Providers (add with backup links, edit,
  switch off, move up/down, remove, refresh, status with counts, connections, expiry and each
  link's state) and Live TV (merged groups, channels with numbers and now/next). Text fields open
  the keyboard on OK only, so moving through a form never traps the remote.
- Tests: 7 bridge tests (Mac and Android), and Android app tests on the emulator for the shared
  fixtures, the login vault, and the real core through JNI (including emoji).
- Compose needs compileSdk 37 (Android SDK platform 37.0 installed); the app still targets 36
  and runs from Android 9.

- Network and sleep events from Kotlin (`SystemMonitor`: ConnectivityManager, and the app leaving
  or returning to the screen) reach the core's playback through `PushedSystemEvents`.
- Channel logos through a small loader of our own (`images/ImageLoader.kt`): web URLs only, 15 MB
  limit, decoded at display size, memory cache sized for the device, 150 MB disk cache.
- Back from a screen's content returns to the sidebar; Back there leaves the app.
- `AndroidTV/THIRD-PARTY-NOTICES.md` lists everything the Android app bundles, with full licence
  texts, and ships inside the APK. The Android build is pinned to GRDB 7.11.1, like the Mac.
- The stream harness builds logo URLs from the request's host, so the emulator (which reaches
  the Mac as 10.0.2.2) loads them.

### Phase 3: playback

- ExoPlayer `PlaybackEngine`; the shared `PlaybackController` drives it (reconnect, format and
  provider fallback, server-link failover mid-stream).
- Full-screen player, remote zapping, number entry, info banner, previous channel.
- Measure channel-change time and memory on the onn HD stick.

Done 2026-11-04 (branch `android/phase-3-playback`), on the emulator:

- `EngineKind.exoPlayer`, and the fallback ladder uses only the platform's engines
  (`PlaybackSettings.engines`): on Android it goes through formats, then providers. Saved engines
  the platform lacks are ignored. The Mac's ladder is unchanged (its tests pass as before).
- Shared player setup (`AppEnvironment.playbackDependencies`, `playbackSettings(engines:)`) and
  zapping rules (`ZapList`: up/down wrap, numbers, previous channel), used by the Mac too.
- `BridgedEngine` (shared): the core's PlaybackController drives an engine in the app. Commands go
  to Kotlin synchronously on the UI thread (the core's main actor runs there); ExoPlayer's events
  come back through `nativePlayerEvent` with the load id. `BridgePlayer` adds the zap list and
  Recents; `player.*` requests and `player` events carry its state. Tested on the Mac and on
  Android with a fake engine (load URL, 404 → next format, zapping, Recents).
- `player/ExoEngine.kt`: ExoPlayer per player, user agent and timeouts per load, buffer from the
  preset (at most 24 MB on low-RAM devices), byte counter for the stall watchdog, errors mapped to
  the core's kinds (HTTP status kept, so 404 skips a rung), tracks and metrics.
- Player screen: full-screen video, info banner (number, logo, name, provider, now with progress,
  next) on channel change and OK, status for opening, reconnecting, waiting for the network and
  failure (with Try again). Up/down and CH+/CH- zap (up = up the list, as on the Mac), number
  keys, last-channel key, Back closes and returns to the channel that was playing.
- On the emulator: channel change about 1 s; the HEVC test channel's TS failed to decode on the
  emulator and the core moved to HLS by itself; a stalled stream reconnected in 1.8 s; closing
  released the provider connection; memory while playing 69.5 MB (PSS).

Still to do: an audio and subtitle menu (the bridge has `player.tracks`/`selectTrack`), and the
measurements on the onn HD stick.

### Phase 4: guide, favorites, recents

- Guide grid (Compose, or the custom view if the spike says so), now line, jump to now,
  programme details.
- Favorites and Recents, with the shared rules.

### Phase 5: movies, series, search, settings

- VOD shelves, details, resume; search; remaining settings (regions, hidden, sidebar sections,
  refresh, playback, About, acknowledgements).

### Phase 5b: multiview

- Read each device's decoder limits, offer only the tile counts it can play. Tiles share the
  shared core's `SourceSelector` and connection accounting, so slots are never over-used.
- Measure on both onn devices: tiles that play smoothly, memory, and what happens when one more
  tile is asked for than the decoder allows (a clear message, never a frozen tile).

### Phase 6: updates and releasing

- In-app updater (signature check, PackageInstaller), APK signing key, `publish.sh` for both
  platforms, platform markers, the extended verification.
- First public Android release; the Downloader code is created after that release exists.

### Phase 7: low-end polish

- Baseline profiles, memory trims (smaller guide window on low-RAM devices, image cache caps),
  frame-timing pass on the guide and lists, final check against every budget on the onn HD
  stick.

## Dependencies needing approval

Jackson's rule: ask before adding any third-party dependency beyond the playback engine and the
database library. For Android:

| Dependency | Why | Licence |
|---|---|---|
| Media3 ExoPlayer (+ HLS module) | the Android playback engine | Apache-2.0 |
| AndroidX (core, activity, lifecycle, Compose for TV) | the platform UI toolkit | Apache-2.0 |
| swift-java | the Kotlin ↔ Swift bridge (approved; not used for now, see "The bridge") | Apache-2.0 |
| swift-crypto | Ed25519 update signatures on Android | Apache-2.0 |
| Optional: Media3 FFmpeg audio extension | AC-3 on devices without a decoder | LGPL |
| Optional: Coil | images, only if our own loader falls short | Apache-2.0 |

All licences go in the Android app's acknowledgements, as on the Mac.

## Fallback if Swift on Android fails the spike

A separate core in plain Kotlin (Kotlin coroutines, SQLite through SQLDelight or Room, the
platform HTTP client), ported from `IPTVCore` with its fixtures. The Mac stays on Swift.
Keeping the two in step then relies on running both test suites against the same fixture files
in `Shared/LumioCore/Tests/IPTVCoreTests/Fixtures` and on the behaviour docs. Every logic change
costs roughly twice as much in that setup, which is why it's the fallback.

## Decided

- Target devices: onn. Google TV Full HD stick (2023) as the minimum, onn. 4K box (2023) as the
  common case (2026-11-03).
- Fire TV isn't a target; older Fire TV devices can be dropped (2026-11-03).
- Folder layout as above, with every file labelled by the app that uses it (2026-11-03).
- The Downloader code points straight at the APK (2026-11-03).
- The Android tooling is installed (2026-11-03).

## Open questions for Jackson

1. Approval of the app dependencies listed under "Dependencies needing approval" (Media3,
   AndroidX, swift-java, swift-crypto), needed from phase 0's test app onwards.
