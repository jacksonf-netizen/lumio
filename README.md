# Lumio

Lumio is an IPTV player for the Mac and for Android TV and Google TV. It plays live TV, movies and
series from Xtream Codes providers, and it's built for live TV first.

- Live TV with logos, what's on now and next, and a guide of what's on later.
- Several providers at once. Channels they share are merged, and when one provider's stream fails,
  Lumio switches to another's.
- Backup server links: paste every link your seller sent, and Lumio moves to the next when one goes
  down. A dropped stream reconnects by itself.
- Movies and series, with posters and details, that resume where you stopped.
- Multiview: up to four channels at once, spread across your providers' connections.
- Search across channels, programmes, movies and series.
- Favorites, recents, your own groups, and hiding the regions and groups you don't watch.
- Signed updates from this page, with no analytics or tracking.

> [!IMPORTANT]
> **Lumio doesn't provide any content.** It includes no channels, streams, playlists or logins, and
> it doesn't sell or point you to any. You need your own subscription from an IPTV provider and the
> Xtream Codes login they give you (a server address, username and password). You're responsible
> for using Lumio only with services you're entitled to.

## Install on a Mac

You need a Mac with Apple silicon (M1 or later) and macOS 14 or later.

1. Download `Lumio-x.y.z.dmg` from the
   [latest release](https://github.com/jacksonf-netizen/lumio/releases/latest), open it and drag
   Lumio to Applications.
2. Open Lumio. The first time, macOS says it can't check the app for malicious software, because
   Lumio isn't signed with a paid Apple developer certificate. Click Done, open System Settings →
   Privacy & Security, scroll down, click Open Anyway next to Lumio and confirm. You only do this
   once.
3. Add your provider in Settings → Providers.

## Install on Android TV or Google TV

You need Android 9 or later.

1. On the TV, install **Downloader** (by AFTVnews) from the Google Play Store.
2. Let Downloader install apps: Settings → Apps → Security & restrictions → Unknown sources →
   Downloader. The menu names differ a little between TVs.
3. Open Downloader, enter this address and install:
   `https://github.com/jacksonf-netizen/lumio/releases/latest/download/Lumio-AndroidTV.apk`
4. Open Lumio and add your provider in Settings → Providers.

## Updates

Both apps check this page for a new version when they open, show what's new and ask before
installing anything. Lumio installs an update only if it's signed with the developer's key. On a
TV, Android asks you to confirm each update, and the first time, to let Lumio install apps. On a
Mac you can turn the check off in Settings → About.

## Using the player

On a Mac:

| Key | Does |
|---|---|
| ↑ ↓ or Page Up / Page Down | Previous or next channel |
| 0–9 | Go to a channel number |
| ⌫ or L | Last channel |
| G | Guide over the video |
| M | Multiview (1–4 pick the tile you hear) |
| D, or the ⓘ button | Stream info |
| I | Channel banner |
| F | Full screen |
| Space | Pause |
| ← → | Back 10 s, forward 30 s (movies and episodes) |
| Esc | Closes the top-most thing, then the player |

Right-click a channel to favorite, rename or hide it, add it to a group, fix its guide match, or
choose which provider's copy it uses. The Window menu opens the guide or the player in a window of
its own.

On a TV, up and down (or the channel buttons) change channel, the number buttons go to a channel,
OK shows the channel banner, and holding OK opens Multiview and the audio and subtitle choices.

## Changing accounts or servers

When your subscription ends or your seller gives you a new login, edit the provider in Settings →
Providers instead of removing it: removing a provider deletes its favorites, recents and watch
history. If the seller moves you to a different panel, Lumio matches the old channels, movies and
series to the new ones at the next refresh and moves your library over, leaving alone anything it
can't match with certainty.

## Privacy and security

Your provider logins are kept only in the macOS Keychain or the Android Keystore, never in Lumio's
database, backups or logs. Lumio talks to your providers, the logo and poster hosts they list, and
GitHub (to check for updates, with nothing about you or your providers in the request). On the Mac
it runs in the App Sandbox.

Most Xtream providers use plain HTTP, and the Xtream protocol puts your username and password in
every stream address, so anyone who can watch your network traffic can see them. Only a provider
that offers HTTPS fixes that.

## Known limitations

- Catch-up, timeshift, recording, and M3U or Stalker playlists aren't supported.
- Movies and series aren't merged across providers the way live channels are, and there's no
  automatic "next episode".
- On a Mac, Picture in Picture works only for streams playing through AVPlayer (HLS), and with four
  multiview tiles playing for hours, memory use slowly grows (about 2 MB a minute).
- On a TV, multiview has as many tiles as the TV's video decoder can play at once (2 on some
  sticks), and there are no extra windows or backups.

## Licence and credits

Lumio's own code is released under the [MIT licence](LICENSE). The Mac app plays video with
[MPVKit](https://github.com/mpvkit/MPVKit) ([mpv](https://mpv.io) and [FFmpeg](https://ffmpeg.org)),
the TV app with [Media3](https://developer.android.com/media/media3), and both use
[GRDB.swift](https://github.com/groue/GRDB.swift). These and every other bundled component keep
their own licences. [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) (Mac) and
[AndroidTV/THIRD-PARTY-NOTICES.md](AndroidTV/THIRD-PARTY-NOTICES.md) (TV) list each one, and the Mac
file explains how to get the source of the LGPL libraries. Each app also shows its notices under
Settings → About.

Lumio isn't affiliated with Xtream Codes or with any IPTV provider.

## Building it yourself

Lumio is written in Swift (SwiftUI on the Mac); the TV app is Kotlin and Compose, sharing Lumio's
Swift core. For the Mac app you need Xcode 27 (26.6 also works) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen --spec Mac/project.yml
open Mac/Lumio.xcodeproj
```

Then choose the IPTVMac scheme and press ⌘R. [Docs/Mac/development.md](Docs/Mac/development.md)
covers testing, the stream test harness, debugging and releases;
[AndroidTV/README.md](AndroidTV/README.md) covers building the TV app.
[CHANGELOG.md](CHANGELOG.md) lists what changed in each version.

| Folder | What it is |
|---|---|
| `Shared/` | Code both apps use: providers, sync, the guide, the database, server links, the reconnect logic, and their tests |
| `Mac/` | The Mac app |
| `AndroidTV/` | The Android TV and Google TV app |
| `Tools/` | The test servers, publishing releases, the secrets check |
| `Docs/` | `Shared/`, `Mac/` and `AndroidTV/` docs, matching the folders above |
