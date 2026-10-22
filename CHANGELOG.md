# Changelog

Notable changes to Lumio (formerly IPTV Streamer). Versions follow [semantic versioning](https://semver.org):
the version in `project.yml` (`MARKETING_VERSION`) and the release tag (`vX.Y.Z`) always match.

## Unreleased

- The acknowledgements now credit every library bundled with Lumio, with its version, licence,
  copyright notice and full licence text, and explain how to get the source of the LGPL libraries.
- Lumio says more clearly that it doesn't provide any content: you need your own IPTV
  subscription and Xtream Codes login (on the welcome screen, when adding a provider, and in
  Settings → About).
- The README is shorter and up to date; developer documentation moved to Docs/development.md.

## 0.1.0 — 2026-10-21

The first public release.

- **Live TV** from Xtream Codes providers, several at once, with a live preview, channel numbers,
  logos, now/next and a player that reconnects by itself when a stream drops.
- **Guide** with a timeline, **Recents** and an organisable **Favorites** guide.
- **Movies and Series** with posters, details, seasons and episodes, and resume where you left off.
- **Multiview**: up to four channels at once.
- **Search** across channels, programmes, movies and series.
- **Live TV Regions**: hide whole regions of a provider's lineup (UK, US, …) or single groups.
- Stream info (resolution, frame rate, video format) in the player.
- **Updates itself**: Lumio checks for a new version when it opens and, if you say yes, downloads it,
  checks it's genuine, installs it and reopens.
- Backup and restore of favorites, settings and layout (never your logins). Logins are kept in the
  macOS Keychain.

Lumio is a player only: you need your own IPTV subscription.

## Before 0.1.0 (development)

The first complete build had Xtream Codes providers (several at once), live TV with preview and a
self-healing player (reconnects, format/engine fallback, cross-provider failover), EPG guide,
movies and series with resume, multiview, global search, settings, backup/restore.
Changes after that, before the first release:


### Added
- The channel banner and movie title show resolution, frame rate and video format, and the player
  has an ⓘ button for full stream info.
- **Recents**: a new first page (the app opens on it) showing recently watched channels as a guide,
  most recent first. Right-click to remove a channel or clear the list.
- **Favorites** shows favorite channels as a guide you can reorder by dragging (or Move to Top /
  Bottom), with tabs for favorite movies and series.
- **Recently Watched** row at the top of Movies and Series, replacing Continue Watching. In-progress
  items resume; others open their page. Right-click to remove one or clear the row.
- Search results are grouped by provider when you have more than one.
- **Settings → Regions**: switch off whole regions of a provider's live lineup ("UK | …",
  "[US] …"). Hidden regions disappear from Live TV, the Guide and Search, including groups added
  later; Movies and Series aren't affected. Providers' different spellings of a region (US / USA / NA, UK / GB…) are combined,
  and you can merge or split regions yourself. Country names without a separator ("SWEDEN HD"),
  unfamiliar codes ("BEE|") and codes a provider uses its own way ("IS| ISRAEL") are recognised.
- Every group is in Settings → Regions: unrecognised ones under **Other Groups**, and each region
  opens to switch single groups on or off.
- When a provider moves to a different panel and renumbers everything, favorites, recents, watch
  progress, renamed or hidden channels, custom groups and guide matches follow to the new IDs.
- Add channels to Favorites straight from Search (star button or right-click).

### Changed
- The app is now called **Lumio**. Providers, favorites, settings and stored logins carry over;
  installing removes the old IPTV Streamer.app.
- **Multiview** is no longer a sidebar page. Open it from a playing channel (M, the grid button,
  or ⌥⌘M); it fills the window like the player, and Esc returns to the player.
- Settings remembers the last tab you used.
- The guide no longer has day buttons; scroll to other days, and use **Now** to jump back.
- Groundwork for publishing: update checks against GitHub Releases (off unless configured),
  Settings → About, third-party notices, a release script, a secrets check and a CI workflow.

### Fixed
- After editing a provider's login or server address, playback kept using the old details until the
  app was restarted. The new details now apply to the next channel.
- Saving a new login while a refresh was running reused that refresh (still on the old login), so
  the provider could show the old account's error. Saving now restarts the refresh.
- A provider briefly answering with an empty list no longer wipes the stored channels, movies or
  series; an empty list is accepted only when the next refresh agrees.
- Posters and backdrops on detail pages are no longer blurry after the same image was shown small.
- Restoring a backup with region merges applies them straight away.

### Security
- Logo, poster and guide-icon links from providers must be http(s); local files and other schemes
  are ignored.
- Size limits on images (15 MB), guide downloads (2 GB) and uncompressed guides (6 GB).
- User-agent values are cleaned of control characters before being sent.
- Update checks only offer and open https GitHub links; the repository setting is validated.
- Engine error messages are redacted before being shown or logged.
- Release builds no longer carry the `get-task-allow` entitlement, so debuggers can't attach to them.
- The player's guide overlay and stream info can be closed with the mouse: a ✕ button, or a click
  on the video around the guide. Esc closes stream info before it closes the player.
- Scrolling the guide (Recents, Guide, Favorites) no longer shows rows above the time bar or below
  the guide: the guide now clips its drawing to its own area.
- The diagnostics overlay (D) showed a buffer of 0 s for most live streams. It now shows how far the
  player has buffered ahead (typically a few seconds).
- Test harness: the HEVC channel no longer stutters. Channels are encoded once and shared, new
  viewers get a few seconds of backlog as with a real server, and HEVC is encoded for low latency.
- The Dock showed a blank icon while the app was running (stale copies of the app were registered).
  `Tools/install.sh` now installs a single copy in /Applications, and build copies are kept out of
  Spotlight.
- Double-clicking a Multiview tile no longer fails with "too many connections": every tile now
  closes before the full-window player opens.
