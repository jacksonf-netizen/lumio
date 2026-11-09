# Lumio: notes for Claude

Lumio is an IPTV player for Xtream Codes providers: a macOS app (Swift/SwiftUI, mpv) and an
Android TV / Google TV app (Kotlin, Compose for TV, Media3), sharing one Swift core
(`Shared/LumioCore`) that the Android app reaches through a JSON bridge (`IPTVBridge`).
Jackson knows Python and is new to Swift and Kotlin: explain things plainly.

Start with `Docs/Mac/development.md` (building, testing, releasing) and `Docs/AndroidTV/plan.md`
(the Android plan, with a "Done" section per phase and what's still to do).

## Rules

- Never commit real credentials. Test fixtures live in test folders; secrets for manual testing go
  in the git-ignored `LocalSecrets.json`. Run `python3 Tools/check_secrets.py` before pushing.
- Never use Jackson's real provider login. Test against `Tools/StreamHarness/harness.py`
  (credentials test/test).
- Logins are stored only in the macOS Keychain / Android Keystore, never in plain files, settings
  or logs. Never log credentials (`CredentialRedactor`).
- Network calls only to the user's own providers, their logo/poster hosts, and GitHub (update
  checks). No analytics, telemetry or third-party services.
- Ask before adding any third-party dependency. Approved: GRDB, MPVKit (LGPL), Media3, AndroidX /
  Compose for TV, swift-crypto (and swift-java, unused).
- The Mac app is the priority; Android must not change how the Mac behaves unless intended (and
  then it goes in the changelog).
- Never change the Mac signing team (`RELEASE_TEAM_ID` WJ9633G98F in `Mac/project.yml`).
- Logic that both apps need goes in the shared core, with tests, and both apps use it.

## Git and pull requests

- Work on a branch per phase (`android/phase-N-…`) and open a PR to `main`. Commit and push freely.
- No force-push. PRs are squash-merged; to bring the squashed `main` into a follow-on branch, check
  that `main`'s tree equals the merged branch's head, then `git merge -s ours origin/main`.
- When a PR is stacked on another, retarget it to `main` before merging and deleting its base,
  or GitHub closes it.
- GitHub auto-merge is off for this repository; merge by hand once checks pass, when Jackson has
  asked for it.
- Releases (`Tools/Release/publish.sh`) need Jackson's go-ahead: they're public and every copy is
  offered the update. When a new release comes out, the previous GitHub release is deleted and its
  tag kept (`publish.sh` does this).

## What only works on Jackson's Mac

A cloud session can edit code, run the shared Swift tests on Linux where they build, and push. These
need Jackson's Mac:

- Publishing a release: the update signing key ("Lumio update signing key") and the APK signing key
  ("Lumio Android signing key") are only in his login Keychain.
- Building and running the Mac app (Xcode 27, MPVKit) and its smoke test.
- The Android build (Swift SDK for Android, NDK r30, `AndroidTV/Tools/env.sh`), the
  `Lumio_GoogleTV_12` emulator and device tests, and the onn TV devices.
- CI (GitHub Actions) builds and tests both apps on every PR, so changes made elsewhere still get
  checked there.

## Where things stand (2026-11-09)

- Android phases 0–6 are merged. 0.3.0 is published: the Android TV redesign (icon rail, two-pane
  Settings, Settings → Display → Size, adaptive icon), grey on both apps with the icon's cyan as
  the accent (the Mac's `AccentColor` asset), and server links read several to a line.
- The Downloader code is **9446363** (AFTVnews; it points at
  `https://github.com/jacksonf-netizen/lumio/releases/latest/download/Lumio-AndroidTV.apk`, so it
  never needs changing). The README and `publish.sh`'s release notes give it.
- Still open: trying the last step of an in-app update on a TV (allowing installs and Android's
  Install prompt) by updating a 0.2.0 copy to 0.3.0; the redesign on the onn TVs; measurements on
  the onn HD stick and 4K box (need wireless debugging); phase 7 (low-end polish).
