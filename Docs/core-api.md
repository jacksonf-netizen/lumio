# IPTVCore public interfaces

`IPTVCore` is the portable heart of the app. It depends only on Foundation, GRDB (SQLite) and, for
two narrow things, Apple system libraries: `Security` (Keychain, behind `SecretStore`) and `os`
(logging). It contains no SwiftUI, AppKit or AVFoundation code. Everything below could be compiled
with Swift on another platform (with a different `SecretStore` and logger), or reimplemented by
following this document together with [schema.md](schema.md) and
[reconnect-state-machine.md](reconnect-state-machine.md).

Source: `Packages/IPTVKit/Sources/IPTVCore/`.

## Conventions

- All model types are `Sendable` value types and carry a `providerID` when they belong to a provider.
- Repositories are structs wrapping an `AppDatabase`. Writes are transactions; reads are snapshots.
- Time is injected through `AppClock` wherever code waits or timestamps.
- Errors shown to users conform to `CustomStringConvertible` / `LocalizedError` and never contain
  credentials (see `CredentialRedactor`).

## Storage and security

| Type | Purpose |
|---|---|
| `AppDatabase` | Opens the SQLite database (`open(at:)`, `inMemory()`), runs migrations, exposes `reader`/`writer`. |
| `SecretStore` | `save` / `load` / `delete` credentials per provider. `KeychainSecretStore` (macOS Keychain), `InMemorySecretStore` (tests, dev). |
| `CredentialRedactor` | `redact(_:credentials:)` masks Xtream stream paths, `username=`/`password=` parameters, URL user-info and literal credentials. |
| `Log` | Named `os.Logger`s: app, database, network, sync, epg, connections, playback, security. |
| `AppClock` | `now()`, `sleep(for:)`. `SystemClock` in production. |

## Providers and sources

| Type | Purpose |
|---|---|
| `Provider`, `ProviderID`, `ProviderCredentials` | Account configuration (no secrets) and its id. |
| `ProviderService` | `addProvider`, `updateProvider`, `removeProvider` (row + Keychain kept consistent), `credentials(for:)`. |
| `ProviderRepository` | CRUD, `reorder`, `observeAll()` (async sequence of the provider list). |
| `ServerURL.normalize(_:)` | Turns user input into a clean base URL; rejects embedded credentials. |
| `SourceProvider` (protocol) | What any source must offer: account, categories, channels, movies, series, details, short EPG, guide download, stream URLs. M3U or Stalker would be new conformances. |
| `XtreamSourceProvider`, `XtreamClient` | Xtream Codes implementation (`player_api.php`, `xmltv.php`), with defensive decoding. |
| `HTTPTransport` | The network seam (`data(for:)`, `download(for:)`); `URLSessionTransport` in production. |
| `XtreamError` | Typed, user-readable failures (unauthorized, expired, 403, 404, max connections, timeout, offline…). |

## Catalog, EPG and sync

| Type | Purpose |
|---|---|
| `CatalogRepository` | Diff-based `replaceCategories/Channels/Movies/Series`, details writes, counts. Only changed rows are written. |
| `CatalogSyncService` (actor) | `refresh(_:parts:)`, `refreshStale(force:)`, `cancel`, `events()` → `SyncEvent` stream. One refresh per provider at a time. |
| `EPGImporter` | `importGuide(file:providerID:window:progress:)`: streaming gzip/XML import in batches; `prune`. |
| `XMLTVParser`, `XMLTVStaging` (internal) | SAX parsing; gzip inflate + repair of bare `&`, HTML entities and control characters. |
| `EPGRepository`, `GuideRepository` | Programme reads for a channel set and time window, applying each provider's time offset; `nowNext`. |
| `EPGKey.normalize` | The single normalisation for EPG ids (trim + lowercase). |

## Live TV model

| Type | Purpose |
|---|---|
| `ChannelMatcher` | Pure function: channels from all providers → logical channels (EPG id, normalised name, quality, overrides). |
| `LogicalChannelStore` | Rebuilds the derived tables; `sources(of:)`, `setOverride` (link/unlink). |
| `LiveCatalog` | Groups (merged by name across providers, or per provider) and channel rows with customisations applied. |
| `LibraryRepository` | Favorites (ordered), recents (`recordPlayed`, `removeRecent`, `clearRecents`), hide/rename/reorder, custom groups, EPG matching, per-channel engine/format, watch progress. |
| `SettingsRepository`, `SettingKey`, `SettingScope` | Typed JSON settings at global / provider / channel scope, with `resolved(...)` fallback. |
| `SyncProvider` (protocol) | Hook for future cloud sync; `LocalOnlySyncProvider` does nothing. |

## Connections and playback

| Type | Purpose |
|---|---|
| `ConnectionManager` (actor) | Slot accounting per provider: `setLimit`, `acquire(_:purpose:onPreempt:)`, `acquireFirstAvailable`, `release`, `usage`, `snapshot`. Previews are preemptible. |
| `SourceSelector` | `rank(_:capacity:)` and `assignTiles(_:capacity:pinned:)` (optimal multiview assignment), `updatedReliability`. |
| `PlaybackEngine` (protocol, main actor) | `load` → load id, `play`, `pause`, `stop` (closes the stream), `seek`, volume, mute, tracks, `metrics()`, `events`. |
| `EngineRequest`, `EngineEvent`, `EngineFailure`, `PlaybackMetrics`, `MediaTrack`, `BufferPreset` | Engine inputs and outputs. |
| `PlaybackItem`, `PlaybackSource`, `PlaybackPlan`, `FallbackLadder` | What to play, from which providers, and the ordered fallbacks. |
| `PlaybackController` (main actor, `@Observable`) | The reconnect state machine: `play(_:debounce:)`, `stop()`, `retry()`, `pause/resume/seek`, tracks; publishes `phase`, `plan`, `metrics`, `reconnectCount`, `notice`, `redactedURL`. |
| `PlaybackDependencies` | Everything the controller needs, injectable: connections, `StreamURLResolver`, `PlaybackHistoryStore`, `SystemEventSource`, clock, engine factory, jitter. |
| `PlaybackSettings` | Timeouts, attempts per rung, backoff, debounce. |
| `PlaybackItemBuilder` | Builds items from the database (live with all sources, movie, episode). |
| `StreamURLResolver` / `ProviderStreamResolver` | The only place credentials meet stream URLs. |
| `PlaybackHistoryStore` / `DatabasePlaybackHistory` | Remembers what worked per channel source. |
| `SystemEventSource` | Network availability and sleep/wake (macOS implementation lives in IPTVPlayback). |

## VOD, search, backup

| Type | Purpose |
|---|---|
| `VODCatalog` | Categories, items (search, recent, keys), `recentlyWatched` (one entry per series), Continue Watching, seasons, episodes, progress, `nextEpisode`. |
| `SearchRepository` | FTS5 prefix search over channels (including custom names), upcoming programmes, movies and series. `SearchResults.grouped(by:)` splits results by provider in priority order. |
| `BackupService` | `export()` / `importBackup(_:)`: versioned JSON, no credentials, providers matched by server URL. |

## Updates

| Type | Purpose |
|---|---|
| `SemanticVersion` | Parses and orders versions ("v1.2", "1.3.0-beta.2"); pre-releases sort before the release. |
| `UpdateFeed` | Where releases are published (`.gitHub(owner:repository:)`), read from the `IPTVUpdateRepository` Info.plist value. |
| `UpdateChecker` | `check()` → `.upToDate` or `.available(AvailableUpdate)` from the latest GitHub release: the .dmg for manual download, and the signed .zip + .zip.sig for installing (`canInstall`). Never called unless a feed is configured. |

`SemanticVersion` and the following live in the **LumioUpdate** module (Foundation + CryptoKit), shared with the installer service; IPTVCore re-exports it.

| Type | Purpose |
|---|---|
| `UpdateSignature` | Ed25519 over "lumio-update-v1" + SHA-256 of the archive. `verify(fileAt:signature:publicKey:)`; the release tool (`Tools/Release/sign_update.swift`) signs. |
| `UpdateInstaller` | `install(archive:signature:)`: copies the archive, verifies it, unpacks it, checks bundle ID / newer version / code signature, clears quarantine and swaps the app in. Runs in `App/LumioInstaller` (XPC service). |
| `InstallerServiceProtocol`, `installerServiceName` | The XPC interface between the app and its installer service. |
