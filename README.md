# Lumio

Lumio is a macOS app for watching IPTV from Xtream Codes providers. It's built for live TV first,
with a channel guide, a player that reconnects by itself when a stream drops, and support for
several providers at once. It also plays your provider's movies and series.

> [!IMPORTANT]
> **Lumio doesn't provide any content.** It includes no channels, streams, playlists or logins, and
> it doesn't sell or point you to any. To use it you need your own subscription from an IPTV
> provider and the Xtream Codes login they give you (a server address, username and password).
> You're responsible for using Lumio only with services you're entitled to.

## Install

You need a Mac with Apple silicon (M1 or later) running macOS 14 or later.

1. Download the latest `Lumio-x.y.z.dmg` from
   [Releases](https://github.com/jacksonf-netizen/lumio/releases/latest), open it and drag Lumio
   to Applications.
2. Open Lumio. The first time, macOS says it can't check the app for malicious software, because
   Lumio isn't signed with a paid Apple developer certificate. Click Done, open System Settings →
   Privacy & Security, scroll down, click Open Anyway next to Lumio and confirm. You only have to
   do this once.
3. Add your provider in Settings → Providers.

Lumio checks for a new version each time it opens. When there is one, it shows what's new and asks
before doing anything; if you say yes, it downloads the update, checks that it's genuine, installs
it and reopens. You can turn the check off in Settings → About.

## What it does

- Live TV with channel numbers, logos, what's on now and next, and a live preview of the selected
  channel. Channels carried by more than one of your providers are merged, and if one provider's
  stream fails, Lumio switches to another.
- A full guide, plus Recents and a Favorites guide you can reorder.
- Movies and series with posters, details, seasons and episodes. Lumio remembers where you stopped.
- Multiview: up to four channels at once, spread across your providers' connections.
- Search across channels, programmes, movies and series.
- Live TV regions: providers often name groups "UK | Sports" or "US: News". Settings → Regions
  lists every region it finds, so you can hide whole regions (or single groups) you don't watch.
- Stream info in the player: resolution, frame rate, video format and more.
- Backup and restore of favorites, layout and settings (your logins are never included).

## Using the player

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

Right-click a channel to favorite, rename or hide it, add it to your own group, fix its guide
match, or choose which provider's copy it uses. Media keys work, and the Window menu opens the
guide or the player in a window of its own (handy on a second display).

## Changing accounts or servers

When your subscription ends, or your seller gives you a new login, edit the provider in Settings →
Providers rather than removing it and adding it again. Removing a provider deletes its favorites,
recents and watch history.

A new login or address on the same panel changes nothing in your library. If the seller moves you
to a different panel, every channel, movie and series gets new IDs; at the next refresh Lumio
matches the old list against the new one (by guide ID, name and region, and for movies by TMDB ID
and year) and moves your favorites, recents, progress and customisations over. If a match isn't
certain, Lumio leaves that entry alone, so nothing gets linked to the wrong channel.

## Privacy and security

Your provider logins are stored only in the macOS Keychain, never in Lumio's database, backups or
logs. Lumio talks to your providers, the logo and poster hosts they list, and GitHub (one request
per launch to check for updates, with nothing about you or your providers in it). There are no
analytics or tracking.

The app runs in the macOS App Sandbox. Updates are signed: Lumio has the developer's public key
built in and installs only an update whose signature matches, from the same app and newer than
the version you have. A small helper inside the app does the install, because a sandboxed app
can't replace itself.

Most Xtream providers use plain HTTP, and the Xtream protocol puts your username and password in
every stream address. Anyone who can watch your network traffic can see them; only a provider that
offers HTTPS fixes that.

## Known limitations

- Picture in Picture works only when a stream plays through AVPlayer (HLS). mpv, the main player,
  can't hand its video to the system PiP window.
- macOS doesn't let apps switch the display's refresh rate to match a stream.
- With four multiview tiles playing for hours, memory use slowly grows (about 2 MB a minute).
- Movies and series aren't merged across providers the way live channels are, and there's no
  automatic "next episode".
- Catch-up, timeshift, recording, and M3U or Stalker playlists aren't supported.
- New users see the macOS warning described under [Install](#install) once.

## Licence and credits

Lumio's own code is released under the [MIT licence](LICENSE). Playback uses
[MPVKit](https://github.com/mpvkit/MPVKit), which packages [mpv](https://mpv.io) and
[FFmpeg](https://ffmpeg.org) with the libraries they need; the library uses
[GRDB.swift](https://github.com/groue/GRDB.swift). These and every other bundled component keep
their own licences (LGPL, MIT, BSD, Apache and others). [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)
lists each one with its version, licence and copyright notice, and explains how to get the source
of the LGPL libraries. The same notices are in the app under Settings → About → Acknowledgements.

Lumio isn't affiliated with Xtream Codes or with any IPTV provider.

## Building it yourself

Lumio is written in Swift and SwiftUI. You need Xcode 27 (26.6 also works) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen
open IPTVStreamer.xcodeproj
```

Then choose the IPTVMac scheme and press ⌘R. [Docs/development.md](Docs/development.md) covers
testing, the stream test harness, debugging and publishing releases, and
[CHANGELOG.md](CHANGELOG.md) lists what changed in each version.
