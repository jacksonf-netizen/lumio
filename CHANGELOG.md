# Changelog

Notable changes to Lumio (formerly IPTV Streamer). Versions follow [semantic versioning](https://semver.org):
the version in `version.properties` (`MARKETING_VERSION`) and the release tag (`vX.Y.Z`) always match.

Each version starts with a one- or two-sentence summary paragraph: that's all Lumio shows when it
offers the update. The list below it appears on the release page.

## Unreleased

## 0.4.0 — 2026-11-09

On Android TV, Live TV is now the programme guide, so there's one place for channels instead of
two. The sidebar only opens a section when you press OK on it.

- Android TV: moving along the sidebar only moves the highlight. A section opens when you press OK
  (or Right) on it; before, resting on one switched to it.
- Android TV: Live TV is now the programme guide, and the separate Guide section is gone. Choose
  Favorites, Recently Watched or a group with the Group button above the channels. Coming in from
  the sidebar lands on the channels.
- Android TV: in Search, Back with the keyboard closed goes to the sidebar in one press.
- The Mac is unchanged.

## 0.3.1 — 2026-11-09

Fixes for Lumio on Android TV: pausing a movie, closing the audio and subtitles panel, and Live TV
showing what's on now. Nothing changes on the Mac.

- Android TV: pausing a movie or episode now shows "Paused" and keeps the controls up, and one
  press of OK resumes. Before, the screen could miss the pause, hide the controls and need OK twice.
- Android TV: Back closes the audio and subtitles panel in one press (it took two).
- Android TV: Live TV rows show what's on as soon as the first guide arrives, and move on to the
  next programme while the list stays open. The player's banner is also current each time it shows.
- Android TV: after adding a channel to Favorites (or closing its options), the remote stays on
  that channel instead of jumping to the group list.
- Mac: the app itself is unchanged. Only its developer smoke test changed, which isn't part of
  the app you install.

## 0.3.0 — 2026-11-09

Lumio on Android TV has a new look, with a slim sidebar, simpler Settings and a size setting, and
it now matches the Mac: dark grey with the icon's cyan. Pasting a list of server links now adds
every link on both apps.

- Android TV: a new look in the Mac's dark greys, with the app icon's cyan as the accent. The
  sidebar is now a slim rail of icons that opens with names when you move onto it; Movies and Series share On Demand, Search is an
  icon at the top and Settings sits at the bottom. Favorites and Recently Watched left the rail:
  they're the first groups in Live TV and the guide. Wherever the remote is, a cyan outline shows
  it.
- Android TV: Settings lists its pages on the left with the chosen page's settings on the right,
  each a row with its current value. A provider's actions (refresh, edit, switch off, reorder,
  remove) open from its row. The Mac is unchanged.
- Android TV: everything is drawn smaller than before, and Settings → Display → Size makes it
  smaller or larger (Smaller, Default, Larger, Largest). The sections you can switch off moved to
  the same page.
- Android TV: the app icon fills its whole circle (navy with the cyan TV), instead of showing the
  wide banner shrunk inside it.
- Android TV: pasting several server links into one link field splits them into a row each, and
  an M3U link with the username and password in it fills those fields, as on the Mac.
- Mac: Lumio's accent is the cyan of its icon instead of the system blue (selections, toggles,
  buttons, the outline on posters), matching Android TV. If you picked an accent colour in System
  Settings → Appearance, Lumio keeps using yours.
- Mac and Android TV: a line with several server links (separated by spaces or commas) adds them
  all. Before, only the first link on a line was kept.

## 0.2.0 — 2026-11-08

Lumio now runs on Android TV and Google TV (Android 9 or later); the release notes say how to
install it. On the Mac, a multiview tile you've just filled waits for a free connection instead of
stopping a tile that's already playing.

- Android TV and Google TV: the first version of Lumio for TVs, made for the remote. It has the
  same providers, live TV, player, guide, Favorites, Recents, Movies and Series (with resume),
  Search and Settings as the Mac, and multiview with 2 to 4 tiles, depending on how many videos
  the TV's decoder can play at once. Not on the TV: extra windows and backup import and export.
- Multiview: when the providers don't have a connection free for every tile, a tile you've just
  filled now waits with the "no free connection" message, instead of a tile that's already playing
  being stopped to make room.
- For developers: the version number lives in `version.properties` at the top of the repository,
  which the Mac and Android TV builds both read.
- For developers: the services' wiring and the Providers screen's rules (adding, editing,
  removing, reordering, refreshing) moved into the shared core, so the Android TV app
  follows the same rules as the Mac.
- For developers: the player's setup, the fallback ladder's choice of engines and the zapping
  rules (channel up/down, numbers, previous channel) are shared with the Android TV app.
- For developers: the Android TV app's guide, Favorites and Recents use the shared core's guide
  reads and Favorites and Recents rules, through new bridge requests.
- For developers: fetching movie and series details, the resume rule, saving watch progress and
  the Movies and Series home page moved into the shared core, so the Mac and Android TV apps
  follow the same rules. Nothing changes in how the Mac app behaves.
- For developers: multiview's tile rules (spreading tiles across providers, sound, layouts, the
  "no free connection" warning) moved into the shared core as `MultiviewSession`, used by the Mac
  and the Android TV app. A new "no free video decoder" failure stops a tile at once, without
  trying other formats and providers.
- For developers: update checks know which app is asking. Each release carries a hidden marker of
  the version in which each app last changed, so an app is only offered an update when there's
  something new for it. `Tools/Release/publish.sh` now builds, signs and checks both apps and
  removes the previous release.
- Android TV: Lumio checks GitHub for updates and installs them itself: it downloads the new
  version, checks its signature, and Android asks you to confirm (and, the first time, to let Lumio
  install apps).
- For developers: CI is split into Mac, Android TV and secrets-check workflows, each running only
  when its part of the repository changes. The Android TV workflow runs the shared core's tests on
  an Android emulator and builds the APK.

## 0.1.7 — 2026-11-04

The guide download is more persistent: it retries timeouts, dropped downloads and flood
protection, and switches to a working server link when the one in use has died.

- If the Mac's hardware video decoder stops responding, Lumio switches to software decoding after
  the first channel, instead of waiting about 15 seconds before every channel, multiview tile and
  movie until the Mac restarts.
- The guide download gives up less easily. A guide that times out, drops halfway or is refused by
  flood protection is tried up to three more times over about a minute and a half, and if the
  address in use has died, Lumio moves to a working link and downloads it from there. Lumio now
  waits a few seconds after loading channels, movies and series before asking for the guide.
- Large guides from slow providers no longer fail after 10 minutes: a download that keeps
  receiving data can take up to an hour.
- For developers: the repository is organised by app. `Shared/` has the code every Lumio app uses,
  `Mac/` the Mac app, `AndroidTV/` the coming Android TV app, and `Docs/` follows the same split.

## 0.1.6 — 2026-11-03

Settings is tidier, with five tabs instead of seven, and you can switch off sidebar sections you
don't use, like Movies or Series.

- Settings has five tabs instead of seven: Providers, General, Playback, Content and About.
  General has the sidebar switches, the refresh schedule and Backup; Content has Live TV Regions
  and Hidden Categories.
- Switch off sidebar sections you don't use (Recents, Live TV, Movies, Series, Favorites, Search)
  in Settings → General → Sidebar. Settings always stays.
- Settings shows a server link that's down as just "Down", without the time it went down.

## 0.1.5 — 2026-11-03

Backup server links that work no longer show as "Down" with providers that have flood
protection. After updating, press Refresh on the provider once to recheck its links.

- Fixed: backup server links that work could show as "Down". Lumio checked every link at the same
  moment, and providers with flood protection answer a burst of requests with "not found". It
  now checks one link at a time, with a short pause, and asks again before calling a link down.
  Press Refresh on the provider once to clear links marked down by mistake.
- Odd refusals some providers send (like 511 or 513 for a wrong login) count as the server
  answering, so a wrong password no longer shows every link as down.
- When a provider has no guide download, Settings says so plainly. Lumio asks once more first,
  in case it was flood protection.

## 0.1.4 — 2026-11-03

Paste every server link your seller sent, and Lumio moves to the next one by itself when the one
in use stops working. Also a quieter look in a few places.

- Backup server links. Paste every link your seller sent into a provider (one per line; M3U or
  stream links with the username and password inside work too, and fill in the login). Lumio
  keeps using the link that works, and when it goes down moves to the next one by itself,
  mid-stream included. It checks the links at launch and every few hours, in the background. A
  link that's still down a day later is marked dead and no longer checked (Refresh in Settings
  tries it again). If none of the links answer, Settings says so, Settings gets a red dot in the
  sidebar, and Live TV shows a banner. Your current address becomes the first link.
- A quieter look in a few places. Programmes on air show a red dot and "Live" (the same red as
  the guide's now line) instead of a red LIVE badge, and Now/Next labels are no longer in capitals.
- Favourite movies and series use the star, like channels, instead of a heart.
- Headings are a little lighter. Posters no longer grow on hover, and a poster that's still
  loading no longer shows its title twice.

## 0.1.3 — 2026-10-22

After this update macOS asks once whether Lumio may access its data (click Allow) and once more
for your Mac password per provider (click Always Allow). From now on, updates shouldn't ask.

- Lumio is now signed with an Apple developer certificate. The certificate from 0.1.1 didn't stop
  macOS asking for your password after each update; this one does, because macOS recognises
  every version as the same app.
- After an update, Lumio reopens as the app pinned in your Dock instead of a second Dock icon.
  This takes effect from the next update, because the updater in your current version does this
  one.
- Removing a provider now always clears its saved login, even one saved by an earlier version.

## 0.1.2 — 2026-10-22

Live TV and Favorites can now switch between a list and a guide, and the Settings tabs no longer
disappear while providers refresh.

- Live TV and Favorites have a List / Guide switch at the top. Guide shows what's on later for
  the group you've picked; Favorites opens as a guide until you choose List, and remembers it.
  The separate Guide section is gone from the sidebar (Window → Guide and G in the player stay).
- The background refresh indicator moved to the bottom of the sidebar. In the toolbar it pushed
  the Settings tabs out of sight while providers were refreshing.

## 0.1.1 — 2026-10-22

Fixes and a shorter Acknowledgements page. After updating, macOS may ask once for your Mac
password so Lumio can keep using its saved logins: enter it and click Always Allow.

- Your providers, favorites and settings stay as they are.
- After this update, macOS may ask once for your Mac password so Lumio can keep using its saved
  logins. Enter it and click Always Allow. Lumio is now signed the same way in every version,
  so later updates won't ask again.
- Fixed: editing a provider while it was refreshing could put its old name or server address back.
- Settings → About → Acknowledgements is now a short list of the open-source projects Lumio uses,
  with the full licence texts one click away. They now cover every bundled library.
- Lumio says more clearly that it doesn't provide any content: you need your own IPTV
  subscription and Xtream Codes login (on the welcome screen, when adding a provider, and in
  Settings → About).
- The updater hands the download to its installer as an open file instead of a path.
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
