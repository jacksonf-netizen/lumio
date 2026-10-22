# Database schema

SQLite via GRDB. The source of truth is `Packages/IPTVKit/Sources/IPTVCore/Database/Migrations.swift`;
keep this document in sync. Migrations are append-only: never edit a shipped migration.

Conventions:
- Column names are camelCase and match the Swift model properties.
- Dates are `REAL` Unix timestamps (seconds since 1970, UTC).
- Booleans are `INTEGER` 0/1. Arrays (e.g. `allowedOutputFormats`) are JSON text.
- Every provider-owned table has `providerID TEXT` with `ON DELETE CASCADE` to `provider(id)`.
  Deleting a provider row removes all of its data. Credentials are not in the database (Keychain).
- WAL journal mode, `synchronous = NORMAL`, foreign keys on.

## Migration v1

### Providers
| Table | Primary key | Notes |
|---|---|---|
| `provider` | `id` | name, kind (`xtream`), serverURL (no credentials), priority (lower = preferred), isEnabled, createdAt, account status from `user_info` (accountStatus, expiresAt, maxConnections, activeConnections, allowedOutputFormats), lastRefreshAt, lastError, epgTimeOffsetMinutes, userAgentOverride |

### Catalog
| Table | Primary key | Notes |
|---|---|---|
| `category` | providerID, kind, categoryID | kind ∈ live/movie/series; sortIndex = provider order |
| `channel` | providerID, streamID | number, name, logoURL, epgChannelID, categoryID, tvArchive, tvArchiveDuration (catch-up, future), addedAt, isAdult, directSource, sortIndex. Indexed on (providerID, categoryID, sortIndex) and epgChannelID |
| `logicalChannel` | id | Derived by channel matching; id is a stable match key like `epg:bbc1.uk` or `name:bbc one` |
| `logicalChannelMember` | providerID, streamID | → logicalChannel(id) and → channel(providerID, streamID), both cascade |
| `channelLinkOverride` | providerID, streamID | Manual link/unlink; action ∈ link/unlink, targetLogicalChannelID. No FK to channel so it survives a channel briefly vanishing from a sync |
| `movie` | providerID, streamID | name, categoryID, posterURL, rating, year, plot, tmdbID, containerExtension, durationSeconds, addedAt, sortIndex |
| `series` | providerID, seriesID | name, categoryID, coverURL, plot, rating, releaseDate, lastModified, sortIndex |
| `season` | providerID, seriesID, seasonNumber | → series cascade |
| `episode` | providerID, episodeID | seriesID, seasonNumber, episodeNumber, title, containerExtension, durationSeconds, plot, imageURL, airDate; → series cascade |

### EPG
| Table | Primary key | Notes |
|---|---|---|
| `epgChannel` | providerID, epgID | XMLTV `<channel>` |
| `programme` | id (autoincrement) | providerID, epgID, start, stop, title, subtitle, summary, category, episodeNumber, iconURL. Unique index (providerID, epgID, start) serves the guide window query and upserts; index on stop serves pruning. Times are stored as published; the provider's offset is applied on read |
| `epgMappingOverride` | providerID, streamID | Manual EPG match: use epgID from epgProviderID's guide (→ provider cascade) |
| `logicalEPGOverride` | logicalChannelID | Use this provider's EPG for a logical channel (→ provider cascade via epgProviderID) |

### Library and customisation
| Table | Primary key | Notes |
|---|---|---|
| `favorite` | providerID, itemKind, itemID | itemKind ∈ channel/movie/series/episode |
| `watchProgress` | providerID, itemKind, itemID | positionSeconds, durationSeconds, isWatched, updatedAt (indexed) |
| `recentItem` | providerID, itemKind, itemID | lastPlayedAt (indexed) |
| `channelOverride` | providerID, streamID | isHidden, customName, sortIndex, engine (mpv/avPlayer), preferredFormat (ts/m3u8) |
| `categoryOverride` | providerID, kind, categoryID | isHidden, customName, sortIndex |
| `customGroup` | id | Cross-provider user group |
| `customGroupMember` | groupID, providerID, streamID | → customGroup and → provider, both cascade |
| `playbackHistory` | providerID, streamID | success/failure counts, reliabilityScore (0–1), lastWorkingFormat, lastWorkingEngine, timestamps, lastError |
| `setting` | scopeKey, key | scopeKey ∈ `global`, `provider:<id>`, `channel:<id>:<streamID>`; providerID set for non-global scopes (cascade); value is JSON |

### Full-text search (FTS5, `unicode61`, diacritics removed)
External-content tables kept in sync by triggers: `channelFTS(name)`, `programmeFTS(title, subtitle)`,
`movieFTS(name)`, `seriesFTS(name)`. Join on `rowid`.

## Migration v2-epg-import

- `programme.importedAt REAL`: when an import last wrote the row. After a *complete* import, rows
  for that provider with an older stamp are deleted (the provider dropped them). Partial imports
  never delete.
- Index `programme_on_provider_importedAt (providerID, importedAt)`.
- `programmeFTS` was rebuilt with hand-written triggers. Re-importing an unchanged guide doesn't
  rewrite the search index: the update trigger only fires when `title` or `subtitle` actually change.

## Migration v3-guide-index

- Index `programme_on_epgID_start (epgID, start)`. The guide reads one EPG id from whichever
  provider has data for it, so it needs an index that doesn't start with `providerID`.

## Migration v4-category-region

- `category.region` (text, nullable) with index `category_on_region`: the region prefix found in
  the category name ("UK" for "UK | Sports"; see `RegionPrefix`). Filled for existing rows by the
  migration and recomputed whenever a sync writes categories.
- Hidden regions are not a table: they're the global setting `hiddenRegions` (a JSON array of
  codes), which queries read with `json_each`. That way backups include them.

## Migration v5-category-region-prefix

- `category.regionPrefix` (text, nullable): the provider's own spelling of the region prefix
  ("NA"), next to `region`, the region it's filed under ("US"). The migration fills both for
  existing rows.
- The user's merges are the global setting `regionAliases` (spelling or region → region). Sync
  applies them when writing categories, and changing them recomputes `region` for every row.

## Migration v6-region-readings

- No schema change. Recomputes `regionPrefix` and `region` for every category with the improved
  rules (`RegionPrefix.resolve`): country names without a separator ("SWEDEN HD"), short codes the
  table doesn't know ("BEE|"), and codes read the way each provider uses them ("IS| ISRAEL" → IL).
- Keeps the user's choices: a region whose groups all came from regions in `hiddenRegions` is added
  to it, so groups that move to a new region stay hidden.

## Migration v7-category-shown

- `categoryOverride.isShown` (boolean, default false): the category stays visible even though its
  region is hidden (Settings → Regions, for a group filed under the wrong region). Together with
  `isHidden`, a category is shown when it isn't hidden by the user and either its region is on or
  `isShown` is set. Categories without a region count as the region `OTHER` ("Other Groups"),
  which can be hidden like any other. Switching a whole region resets both flags inside it.

## Migration v8-episode-relink

- `episodeRelink` (providerID, episodeID, seriesID, seasonNumber, episodeNumber; key providerID +
  episodeID): episodes the library refers to whose series got a new ID when the provider moved
  panels. When that series' episode list is next stored, entries are matched by season and
  episode number, the library is moved to the new episode IDs, and the rows are removed.
- Not a table but related: every catalog replace (`CatalogRepository`) runs `CatalogRelinker`
  first, which moves library rows (favorite, recentItem, watchProgress, channelOverride,
  customGroupMember, playbackHistory, epgMappingOverride, channelLinkOverride, categoryOverride,
  and `solo:` logical IDs in logicalEPGOverride / channelLinkOverride) to new IDs.

## Derived and rebuildable data

`logicalChannel` and `logicalChannelMember` can be deleted and rebuilt at any time from `channel`,
`provider` (enabled + priority) and `channelLinkOverride` (`LogicalChannelStore.rebuild()`).
FTS tables can be rebuilt with `INSERT INTO <fts>(<fts>) VALUES('rebuild')`.
