package com.jackson.lumio.core

import org.json.JSONArray
import org.json.JSONObject

// The core's replies, one class per type in Shared/LumioCore/Sources/IPTVBridge/BridgeModels.swift
// (same field names). A change there needs the same change here; BridgeModelsTest reads the shared
// fixtures (Shared/LumioCore/Tests/IPTVBridgeTests/Fixtures) to check both sides agree.
// Dates are seconds since 1970.

data class ProviderInfo(
    val id: String,
    val name: String,
    val enabled: Boolean,
    val server: String,
    val links: List<ServerLink>,
    val channels: Int,
    val movies: Int,
    val series: Int,
    val programmes: Int,
    val connectionsInUse: Int,
    val connectionLimit: Int,
    val accountStatus: String?,
    val expiresAt: Double?,
    val lastRefreshAt: Double?,
    val lastError: String?,
    /** What a refresh in progress is doing, or null. */
    val syncing: String?,
    val unreachable: Boolean,
) {
    constructor(json: JSONObject) : this(
        id = json.getString("id"),
        name = json.getString("name"),
        enabled = json.getBoolean("enabled"),
        server = json.getString("server"),
        links = json.getJSONArray("links").objects().map(::ServerLink),
        channels = json.getInt("channels"),
        movies = json.getInt("movies"),
        series = json.getInt("series"),
        programmes = json.getInt("programmes"),
        connectionsInUse = json.getInt("connectionsInUse"),
        connectionLimit = json.getInt("connectionLimit"),
        accountStatus = json.text("accountStatus"),
        expiresAt = json.number("expiresAt"),
        lastRefreshAt = json.number("lastRefreshAt"),
        lastError = json.text("lastError"),
        syncing = json.text("syncing"),
        unreachable = json.getBoolean("unreachable"),
    )
}

data class ServerLink(val url: String, val inUse: Boolean, val down: Boolean, val lastCheckedAt: Double?) {
    constructor(json: JSONObject) : this(
        url = json.getString("url"),
        inUse = json.getBoolean("inUse"),
        down = json.getBoolean("down"),
        lastCheckedAt = json.number("lastCheckedAt"),
    )
}

data class ProviderEditor(val servers: String, val username: String) {
    constructor(json: JSONObject) : this(json.getString("servers"), json.getString("username"))
}

data class ChannelGroup(val id: String, val name: String, val kind: String, val hidden: Boolean) {
    constructor(json: JSONObject) : this(
        id = json.getString("id"),
        name = json.getString("name"),
        kind = json.getString("kind"),
        hidden = json.getBoolean("hidden"),
    )
}

data class Channel(
    val id: String,
    val name: String,
    val number: Int?,
    val logo: String?,
    val providerID: String,
    val streamID: Int,
    val favorite: Boolean,
    val hidden: Boolean,
    val catchup: Boolean,
    val epg: EPGRef?,
) {
    constructor(json: JSONObject) : this(
        id = json.getString("id"),
        name = json.getString("name"),
        number = if (json.has("number")) json.getInt("number") else null,
        logo = json.text("logo"),
        providerID = json.getString("providerID"),
        streamID = json.getInt("streamID"),
        favorite = json.getBoolean("favorite"),
        hidden = json.getBoolean("hidden"),
        catchup = json.getBoolean("catchup"),
        epg = json.optJSONObject("epg")?.let(::EPGRef),
    )
}

data class EPGRef(val id: String, val providers: List<String>) {
    constructor(json: JSONObject) : this(json.getString("id"), json.getJSONArray("providers").strings())

    fun toJson(): JSONObject = JSONObject().put("id", id).put("providers", JSONArray(providers))
}

data class NowNext(val epg: EPGRef, val now: Programme?, val next: Programme?) {
    constructor(json: JSONObject) : this(
        epg = EPGRef(json.getJSONObject("epg")),
        now = json.optJSONObject("now")?.let(::Programme),
        next = json.optJSONObject("next")?.let(::Programme),
    )
}

data class Programme(
    val title: String,
    val start: Double,
    val stop: Double,
    val subtitle: String? = null,
    val summary: String? = null,
    val category: String? = null,
    /** The provider's episode number as written ("S2 E5"). */
    val episode: String? = null,
) {
    constructor(json: JSONObject) : this(
        title = json.getString("title"),
        start = json.getDouble("start"),
        stop = json.getDouble("stop"),
        subtitle = json.text("subtitle"),
        summary = json.text("summary"),
        category = json.text("category"),
        episode = json.text("episode"),
    )

    /** On at [now] (seconds since 1970). */
    fun isOn(now: Double): Boolean = start <= now && stop > now

    /** 0–1 through the programme at [now] (seconds since 1970). */
    fun progress(now: Double): Float =
        if (stop <= start) 0f else ((now - start) / (stop - start)).coerceIn(0.0, 1.0).toFloat()
}

/** One guide row: a channel's programmes in the window asked for, in order. */
data class GuideRow(val epg: EPGRef, val programmes: List<Programme>) {
    constructor(json: JSONObject) : this(EPGRef(json.getJSONObject("epg")), json.getJSONArray("programmes").objects().map(::Programme))
}

// MARK: Movies and Series (Shared/LumioCore/Sources/IPTVBridge/BridgeVOD.swift)

data class VODItem(
    /** movie or series. */
    val kind: String,
    val provider: String,
    val id: Int,
    val name: String,
    val poster: String?,
    val rating: Double?,
    val year: Int?,
    /** 0–1 watched (movies). */
    val progress: Double?,
    val favorite: Boolean,
) {
    constructor(json: JSONObject) : this(
        kind = json.getString("kind"),
        provider = json.getString("provider"),
        id = json.getInt("id"),
        name = json.getString("name"),
        poster = json.text("poster"),
        rating = json.number("rating"),
        year = if (json.has("year")) json.getInt("year") else null,
        progress = json.number("progress"),
        favorite = json.getBoolean("favorite"),
    )
}

/** A movie or episode in Recently Watched. */
data class ContinueItem(
    /** movie or episode. */
    val kind: String,
    val provider: String,
    /** The stream id (movie) or episode id. */
    val id: String,
    val title: String,
    val subtitle: String?,
    val image: String?,
    val position: Double,
    val duration: Double?,
    val series: Int?,
    val watched: Boolean,
    val canResume: Boolean,
) {
    constructor(json: JSONObject) : this(
        kind = json.getString("kind"),
        provider = json.getString("provider"),
        id = json.getString("id"),
        title = json.getString("title"),
        subtitle = json.text("subtitle"),
        image = json.text("image"),
        position = json.getDouble("position"),
        duration = json.number("duration"),
        series = if (json.has("series")) json.getInt("series") else null,
        watched = json.getBoolean("watched"),
        canResume = json.getBoolean("canResume"),
    )
}

data class VODCategory(val provider: String, val id: String, val name: String) {
    constructor(json: JSONObject) : this(json.getString("provider"), json.getString("id"), json.getString("name"))
}

data class VODShelf(val category: VODCategory, val items: List<VODItem>) {
    constructor(json: JSONObject) : this(VODCategory(json.getJSONObject("category")), json.getJSONArray("items").objects().map(::VODItem))
}

data class VODHome(
    val recentlyWatched: List<ContinueItem>,
    val recentlyAdded: List<VODItem>,
    val shelves: List<VODShelf>,
    val categories: List<VODCategory>,
) {
    constructor(json: JSONObject) : this(
        recentlyWatched = json.getJSONArray("recentlyWatched").objects().map(::ContinueItem),
        recentlyAdded = json.getJSONArray("recentlyAdded").objects().map(::VODItem),
        shelves = json.getJSONArray("shelves").objects().map(::VODShelf),
        categories = json.getJSONArray("categories").objects().map(::VODCategory),
    )
}

data class WatchProgress(val position: Double, val duration: Double?, val watched: Boolean, val canResume: Boolean) {
    constructor(json: JSONObject) : this(json.getDouble("position"), json.number("duration"), json.getBoolean("watched"),
        json.getBoolean("canResume"))
}

data class MovieInfo(
    val provider: String,
    val providerName: String,
    val id: Int,
    val name: String,
    val poster: String?,
    val backdrop: String?,
    val year: Int?,
    /** Seconds. */
    val duration: Int?,
    val genre: String?,
    val rating: Double?,
    val plot: String?,
    val director: String?,
    val cast: String?,
    val favorite: Boolean,
    val progress: WatchProgress?,
    val detailsError: String?,
) {
    constructor(json: JSONObject) : this(
        provider = json.getString("provider"),
        providerName = json.getString("providerName"),
        id = json.getInt("id"),
        name = json.getString("name"),
        poster = json.text("poster"),
        backdrop = json.text("backdrop"),
        year = if (json.has("year")) json.getInt("year") else null,
        duration = if (json.has("duration")) json.getInt("duration") else null,
        genre = json.text("genre"),
        rating = json.number("rating"),
        plot = json.text("plot"),
        director = json.text("director"),
        cast = json.text("cast"),
        favorite = json.getBoolean("favorite"),
        progress = json.optJSONObject("progress")?.let(::WatchProgress),
        detailsError = json.text("detailsError"),
    )
}

data class Season(val number: Int, val name: String) {
    constructor(json: JSONObject) : this(json.getInt("number"), json.getString("name"))
}

data class Episode(
    val id: String,
    val season: Int,
    val number: Int,
    val title: String,
    val duration: Int?,
    val plot: String?,
    val image: String?,
    val progress: WatchProgress?,
) {
    constructor(json: JSONObject) : this(
        id = json.getString("id"),
        season = json.getInt("season"),
        number = json.getInt("number"),
        title = json.getString("title"),
        duration = if (json.has("duration")) json.getInt("duration") else null,
        plot = json.text("plot"),
        image = json.text("image"),
        progress = json.optJSONObject("progress")?.let(::WatchProgress),
    )
}

data class SeriesInfo(
    val provider: String,
    val providerName: String,
    val id: Int,
    val name: String,
    val cover: String?,
    val year: Int?,
    val rating: Double?,
    val plot: String?,
    val favorite: Boolean,
    val seasons: List<Season>,
    val episodes: List<Episode>,
    /** The episode Play offers. */
    val next: String?,
    val detailsError: String?,
) {
    constructor(json: JSONObject) : this(
        provider = json.getString("provider"),
        providerName = json.getString("providerName"),
        id = json.getInt("id"),
        name = json.getString("name"),
        cover = json.text("cover"),
        year = if (json.has("year")) json.getInt("year") else null,
        rating = json.number("rating"),
        plot = json.text("plot"),
        favorite = json.getBoolean("favorite"),
        seasons = json.getJSONArray("seasons").objects().map(::Season),
        episodes = json.getJSONArray("episodes").objects().map(::Episode),
        next = json.text("next"),
        detailsError = json.text("detailsError"),
    )
}

/** Search results (the core's SearchRepository): word prefixes, ignoring case and accents. */
data class SearchResults(
    val channels: List<Channel>,
    val programmes: List<ProgrammeHit>,
    val movies: List<VODItem>,
    val series: List<VODItem>,
) {
    constructor(json: JSONObject) : this(
        channels = json.getJSONArray("channels").objects().map(::Channel),
        programmes = json.getJSONArray("programmes").objects().map(::ProgrammeHit),
        movies = json.getJSONArray("movies").objects().map(::VODItem),
        series = json.getJSONArray("series").objects().map(::VODItem),
    )

    val isEmpty get() = channels.isEmpty() && programmes.isEmpty() && movies.isEmpty() && series.isEmpty()
}

/** A programme that matched, with a channel showing it (when one does). */
data class ProgrammeHit(val programme: Programme, val channel: Channel?) {
    constructor(json: JSONObject) : this(Programme(json.getJSONObject("programme")), json.optJSONObject("channel")?.let(::Channel))
}

// MARK: Settings (Shared/LumioCore/Sources/IPTVBridge/BridgeSettings.swift)

data class AppSettings(
    val epgRefreshHours: Double,
    val catalogRefreshHours: Double,
    val epgFutureDays: Double,
    /** ts or m3u8. */
    val preferredFormat: String,
    /** lowLatency, normal or large. */
    val bufferPreset: String,
    val stallTimeoutSeconds: Double,
    /** Empty: the default. */
    val userAgent: String,
    val defaultUserAgent: String,
    val hiddenSidebarItems: List<String>,
) {
    constructor(json: JSONObject) : this(
        epgRefreshHours = json.getDouble("epgRefreshHours"),
        catalogRefreshHours = json.getDouble("catalogRefreshHours"),
        epgFutureDays = json.getDouble("epgFutureDays"),
        preferredFormat = json.getString("preferredFormat"),
        bufferPreset = json.getString("bufferPreset"),
        stallTimeoutSeconds = json.getDouble("stallTimeoutSeconds"),
        userAgent = json.getString("userAgent"),
        defaultUserAgent = json.getString("defaultUserAgent"),
        hiddenSidebarItems = json.getJSONArray("hiddenSidebarItems").strings(),
    )
}

data class Region(
    val code: String,
    val name: String,
    val groups: Int,
    val examples: List<String>,
    val shown: Boolean,
    val categoryCount: Int,
    val shownCategories: Int,
    /** Groups without a recognisable region. */
    val other: Boolean,
) {
    constructor(json: JSONObject) : this(
        code = json.getString("code"),
        name = json.getString("name"),
        groups = json.getInt("groups"),
        examples = json.getJSONArray("examples").strings(),
        shown = json.getBoolean("shown"),
        categoryCount = json.getInt("categoryCount"),
        shownCategories = json.getInt("shownCategories"),
        other = json.getBoolean("other"),
    )
}

/** A category in Settings → Content (a region's live group, or a hidden category of any kind). */
data class ContentCategory(
    val provider: String,
    val providerName: String,
    /** live, movie or series. */
    val kind: String,
    val id: String,
    val name: String,
    val shown: Boolean,
) {
    constructor(json: JSONObject) : this(
        provider = json.getString("provider"),
        providerName = json.getString("providerName"),
        kind = json.getString("kind"),
        id = json.getString("id"),
        name = json.getString("name"),
        shown = json.getBoolean("shown"),
    )
}

data class Regions(val regions: List<Region>, val categories: Map<String, List<ContentCategory>>) {
    constructor(json: JSONObject) : this(
        regions = json.getJSONArray("regions").objects().map(::Region),
        categories = json.getJSONObject("categories").let { map ->
            map.keys().asSequence().associateWith { key -> map.getJSONArray(key).objects().map(::ContentCategory) }
        },
    )
}

/** The movie or episode a player is playing. */
data class VODNow(val kind: String, val title: String, val subtitle: String?) {
    constructor(json: JSONObject) : this(json.getString("kind"), json.getString("title"), json.text("subtitle"))
}

/** A player's state (the core's PlayerStateDTO). */
data class PlayerState(
    val player: String,
    /** idle, connecting, buffering, playing, paused, reconnecting, waitingForNetwork, suspended, preempted, ended, failed. */
    val phase: String,
    val attempt: Int?,
    val message: String?,
    val notice: String?,
    val channel: Channel?,
    val provider: String?,
    val hasPrevious: Boolean,
    /** The movie or episode playing; null for live TV. */
    val vod: VODNow? = null,
) {
    constructor(json: JSONObject) : this(
        player = json.getString("player"),
        phase = json.getString("phase"),
        attempt = if (json.has("attempt")) json.getInt("attempt") else null,
        message = json.text("message"),
        notice = json.text("notice"),
        channel = json.optJSONObject("channel")?.let(::Channel),
        provider = json.text("provider"),
        hasPrevious = json.getBoolean("hasPrevious"),
        vod = json.optJSONObject("vod")?.let(::VODNow),
    )
}

data class Track(val id: Int, val kind: String, val name: String, val selected: Boolean) {
    constructor(json: JSONObject) : this(json.getInt("id"), json.getString("kind"), json.getString("name"), json.getBoolean("selected"))
}

/**
 * A change in the core. type: providers, live, guide, vod (watch progress or Recently Watched), player
 * (with state), or sync (with provider, label, finished, error).
 */
/** The result of an update check. See `BridgeUpdate.swift`. */
data class UpdateInfo(
    /** upToDate or available. */
    val status: String,
    val latest: String,
    val title: String?,
    /** The release notes' first paragraph. */
    val summary: String?,
    val pageURL: String?,
    val apkURL: String?,
    val signatureURL: String?,
) {
    val available get() = status == "available"

    constructor(json: JSONObject) : this(
        status = json.getString("status"),
        latest = json.getString("latest"),
        title = json.text("title"),
        summary = json.text("summary"),
        pageURL = json.text("pageURL"),
        apkURL = json.text("apkURL"),
        signatureURL = json.text("signatureURL"),
    )
}

/** Multiview: the tiles and which one is heard. See `BridgeMultiview.swift`. */
data class MultiviewState(
    val active: Boolean,
    /** 2, 3 or 4. */
    val layout: Int,
    val audioTile: Int,
    /** Some tile has no free connection on any provider. */
    val warning: String?,
    val tiles: List<Tile>,
) {
    constructor(json: JSONObject) : this(
        active = json.getBoolean("active"),
        layout = json.getInt("layout"),
        audioTile = json.getInt("audioTile"),
        warning = json.text("warning"),
        tiles = json.getJSONArray("tiles").objects().map(::Tile),
    )
}

data class Tile(
    val index: Int,
    val channel: Channel?,
    /** The Live TV group the channel came from. */
    val group: String?,
    /** As [PlayerState.phase]. */
    val phase: String,
    val attempt: Int?,
    val message: String?,
    val notice: String?,
    /** The provider the tile plays from. */
    val provider: String?,
    val providerID: String?,
    /** The provider chosen for the tile; null for automatic. */
    val pinned: String?,
    /** Every provider carrying the channel. */
    val providers: List<ProviderChoice>,
) {
    constructor(json: JSONObject) : this(
        index = json.getInt("index"),
        channel = json.optJSONObject("channel")?.let(::Channel),
        group = json.text("group"),
        phase = json.getString("phase"),
        attempt = if (json.has("attempt")) json.getInt("attempt") else null,
        message = json.text("message"),
        notice = json.text("notice"),
        provider = json.text("provider"),
        providerID = json.text("providerID"),
        pinned = json.text("pinned"),
        providers = json.getJSONArray("providers").objects().map { ProviderChoice(it.getString("id"), it.getString("name")) },
    )
}

data class ProviderChoice(val id: String, val name: String)

data class BridgeEvent(
    val type: String,
    val provider: String?,
    val label: String?,
    val finished: Boolean,
    val error: String?,
    /** For player events. */
    val state: PlayerState?,
    /** For multiview events. */
    val multiview: MultiviewState? = null,
) {
    constructor(json: JSONObject) : this(
        type = json.getString("type"),
        provider = json.text("provider"),
        label = json.text("label"),
        finished = json.optBoolean("finished", false),
        error = json.text("error"),
        state = json.optJSONObject("state")?.let(::PlayerState),
        multiview = json.optJSONObject("multiview")?.let(::MultiviewState),
    )
}

// MARK: JSON helpers

/** The string at [key], or null when it's missing or JSON null. */
internal fun JSONObject.text(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null

internal fun JSONObject.number(key: String): Double? = if (has(key) && !isNull(key)) getDouble(key) else null

internal fun JSONArray.objects(): List<JSONObject> = List(length()) { getJSONObject(it) }

internal fun JSONArray.strings(): List<String> = List(length()) { getString(it) }
