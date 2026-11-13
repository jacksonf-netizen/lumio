package com.jackson.lumio.core

import android.content.Context
import android.util.Log
import com.jackson.lumio.player.PlayerEngines
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * The shared core (Shared/LumioCore, written in Swift), compiled into liblumiocore.so.
 *
 * Every rule lives there; this only sends requests and reads replies. Requests are JSON, handled by
 * the core's IPTVBridge (the same code the Mac tests exercise); the reply types are in
 * BridgeModels.kt. Changes arrive on [events].
 */
object LumioCore {
    private const val TAG = "Lumio.core"

    init {
        System.loadLibrary("lumiocore")
    }

    private val eventFlow = MutableSharedFlow<BridgeEvent>(extraBufferCapacity = 64)

    /** Changes in the core: providers, the Live TV lists, the guide, refresh progress. */
    val events: SharedFlow<BridgeEvent> = eventFlow.asSharedFlow()

    @Volatile private var started = false

    /** For requests nobody waits for (system events), one at a time so they arrive in order. */
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    private val background = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(1))

    /** Opens the database and starts the core. Call once, on the main thread (Application.onCreate). */
    fun start(context: Context) {
        if (started) return
        started = true
        val vault = LoginVault(context)
        val listener = CoreListener(vault) { event -> eventFlow.tryEmit(event) }
        val database = context.getDatabasePath("lumio.sqlite").apply { parentFile?.mkdirs() }
        val error = nativeStart(database.path.toByteArray(), context.cacheDir.path.toByteArray(), listener)
        if (error != null) Log.e(TAG, "The core didn't start: ${String(error)}")
    }

    // MARK: Requests

    suspend fun providers(): List<ProviderInfo> = call("providers.list").asArray().map(::ProviderInfo)

    suspend fun addProvider(name: String, servers: String, username: String, password: String): String =
        call("providers.add", "name" to name, "servers" to servers, "username" to username, "password" to password)
            .asObject().getString("id")

    /** An empty username or password keeps the saved one. */
    suspend fun saveProvider(id: String, name: String, servers: String, username: String, password: String) {
        call("providers.save", "id" to id, "name" to name, "servers" to servers, "username" to username, "password" to password)
    }

    suspend fun providerEditor(id: String): ProviderEditor = ProviderEditor(call("providers.editor", "id" to id).asObject())

    /** Reads typed or pasted server links as the Mac's link box does; throws with a message when it can't. */
    suspend fun parseLinks(text: String): ParsedLinks = ParsedLinks(call("providers.parseLinks", "text" to text).asObject())

    suspend fun removeProvider(id: String) { call("providers.remove", "id" to id) }

    suspend fun setProviderEnabled(id: String, enabled: Boolean) { call("providers.setEnabled", "id" to id, "enabled" to enabled) }

    suspend fun reorderProviders(ids: List<String>) { call("providers.reorder", "ids" to JSONArray(ids)) }

    /** Refreshes one provider, or every provider when [id] is null. */
    suspend fun refresh(id: String? = null) {
        if (id != null) call("providers.refresh", "id" to id) else call("providers.refresh")
    }

    suspend fun groups(includeHidden: Boolean = false): List<ChannelGroup> =
        call("live.groups", "includeHidden" to includeHidden).asArray().map(::ChannelGroup)

    suspend fun channels(group: String, includeHidden: Boolean = false): List<Channel> =
        call("live.channels", "group" to group, "includeHidden" to includeHidden).asArray().map(::Channel)

    suspend fun nowNext(refs: List<EPGRef>): Map<EPGRef, NowNext> {
        if (refs.isEmpty()) return emptyMap()
        val list = call("live.nowNext", "epg" to JSONArray(refs.map { it.toJson() })).asArray().map(::NowNext)
        return list.associateBy { it.epg }
    }

    /** Programmes between [start] and [end] (seconds since 1970; at most two days) for each channel. */
    suspend fun guide(refs: List<EPGRef>, start: Double, end: Double): Map<EPGRef, List<Programme>> {
        if (refs.isEmpty()) return emptyMap()
        val rows = call("guide.programmes", "epg" to JSONArray(refs.map { it.toJson() }), "start" to start, "end" to end)
            .asArray().map(::GuideRow)
        return rows.associate { it.epg to it.programmes }
    }

    // MARK: Movies and Series (kind: movie or series)

    suspend fun vodHome(kind: String): VODHome = VODHome(call("vod.home", "kind" to kind).asObject())

    /** A page of a category, in the provider's order. */
    suspend fun vodCategory(kind: String, provider: String, category: String, offset: Int, limit: Int = 120): List<VODItem> =
        call("vod.category", "kind" to kind, "provider" to provider, "category" to category, "offset" to offset, "limit" to limit)
            .asArray().map(::VODItem)

    suspend fun vodSearch(kind: String, query: String, limit: Int = 60): List<VODItem> =
        call("vod.search", "kind" to kind, "query" to query, "limit" to limit).asArray().map(::VODItem)

    /** Channels, guide programmes, movies and series matching [text]. */
    suspend fun search(text: String): SearchResults = SearchResults(call("search.query", "text" to text).asObject())

    /** What the catalog has; with [fetch], the provider's full details first (slower). */
    suspend fun movie(provider: String, id: Int, fetch: Boolean = false): MovieInfo =
        MovieInfo(call("vod.movie", "provider" to provider, "id" to id, "fetch" to fetch).asObject())

    /** With [fetch], the seasons and episodes are fetched again from the provider first. */
    suspend fun series(provider: String, id: Int, fetch: Boolean = false): SeriesInfo =
        SeriesInfo(call("vod.series", "provider" to provider, "id" to id, "fetch" to fetch).asObject())

    /**
     * Plays a movie ([kind] movie, [id] its stream id) or an episode ([kind] episode, [id] its episode
     * id) from [position] seconds (null: the start). The core saves the position as it plays.
     */
    suspend fun playVOD(kind: String, provider: String, id: String, position: Double?, title: String, subtitle: String?): PlayerState {
        val params = mutableListOf<Pair<String, Any>>("kind" to kind, "provider" to provider, "id" to id, "title" to title)
        if (position != null && position > 0) params += "position" to position
        if (subtitle != null) params += "subtitle" to subtitle
        return PlayerState(call("vod.play", *params.toTypedArray()) as JSONObject)
    }

    suspend fun setVODFavorite(kind: String, provider: String, id: String, favorite: Boolean) {
        call("vod.setFavorite", "kind" to kind, "provider" to provider, "id" to id, "favorite" to favorite)
    }

    /** [kind] movie or episode. */
    suspend fun setWatched(kind: String, provider: String, id: String, watched: Boolean) {
        call("vod.setWatched", "kind" to kind, "provider" to provider, "id" to id, "watched" to watched)
    }

    /** A movie ([kind] movie, its stream id) or a whole series ([kind] series, its series id). */
    suspend fun removeVODRecent(kind: String, provider: String, id: String) {
        call("vod.removeRecent", "kind" to kind, "provider" to provider, "id" to id)
    }

    suspend fun clearVODRecents(kind: String) { call("vod.clearRecents", "kind" to kind) }

    suspend fun pause(): PlayerState = PlayerState(call("player.pause") as JSONObject)

    suspend fun resume(): PlayerState = PlayerState(call("player.resume") as JSONObject)

    suspend fun seek(position: Double): PlayerState = PlayerState(call("player.seek", "position" to position) as JSONObject)

    // MARK: Settings and content switches

    suspend fun settings(): AppSettings = AppSettings(call("settings.get").asObject())

    /** A number setting (epgRefreshHours, catalogRefreshHours, epgFutureDays, stallTimeoutSeconds). */
    suspend fun setSetting(key: String, number: Double) { call("settings.set", "key" to key, "number" to number) }

    /** A text setting (preferredFormat, bufferPreset, userAgent; empty user agent: the default). */
    suspend fun setSetting(key: String, text: String) { call("settings.set", "key" to key, "text" to text) }

    /** A list setting (hiddenSidebarItems). */
    suspend fun setSetting(key: String, list: List<String>) { call("settings.set", "key" to key, "list" to JSONArray(list)) }

    suspend fun regions(): Regions = Regions(call("content.regions").asObject())

    /** Switching a region on or off resets its single groups. */
    suspend fun setRegion(code: String, shown: Boolean) { call("content.setRegion", "code" to code, "shown" to shown) }

    suspend fun setAllRegions(shown: Boolean) { call("content.setAllRegions", "shown" to shown) }

    suspend fun setRegionCategory(provider: String, id: String, shown: Boolean) {
        call("content.setRegionCategory", "provider" to provider, "id" to id, "shown" to shown)
    }

    suspend fun hiddenCategories(): List<ContentCategory> = call("content.hiddenCategories").asArray().map(::ContentCategory)

    /** [kind] live, movie or series. */
    suspend fun setCategoryHidden(provider: String, kind: String, id: String, hidden: Boolean) {
        call("content.setCategoryHidden", "provider" to provider, "kind" to kind, "id" to id, "hidden" to hidden)
    }

    // MARK: Favorites and Recents (the core's LibraryRepository, as on the Mac)

    /** Adds the channel to Favorites or takes it out. Returns whether it's a favorite now. */
    suspend fun toggleFavorite(channel: String): Boolean =
        call("library.toggleFavorite", "channel" to channel).asObject().getBoolean("favorite")

    /** Moves a favorite to position [to] (0 is the top; past the end is the bottom). */
    suspend fun moveFavorite(channel: String, to: Int) { call("library.moveFavorite", "channel" to channel, "to" to to) }

    suspend fun removeRecent(channel: String) { call("library.removeRecent", "channel" to channel) }

    /** Empties Recently Watched (channels only). */
    suspend fun clearRecents() { call("library.clearRecents") }

    /** network (with [available]), willSleep or didWake. Sent in the background, in order. */
    fun systemEvent(type: String, available: Boolean? = null) {
        background.launch {
            runCatching {
                if (available != null) call("system.event", "type" to type, "available" to available)
                else call("system.event", "type" to type)
            }
        }
    }

    // MARK: Playback (the core's PlaybackController; the engine is player/ExoEngine.kt)

    /** Plays [channel] from [group]; channel up/down then moves through that group. */
    /** [preview]: the guide's small picture, not recorded in Recents. Watching the channel already playing doesn't reopen it. */
    suspend fun watch(channel: String, group: String, preview: Boolean = false): PlayerState =
        PlayerState(call("player.watch", "channel" to channel, "group" to group, "preview" to preview) as JSONObject)

    suspend fun zap(by: Int): PlayerState = PlayerState(call("player.zap", "by" to by) as JSONObject)

    suspend fun channelNumber(number: Int): PlayerState = PlayerState(call("player.number", "number" to number) as JSONObject)

    suspend fun previousChannel(): PlayerState = PlayerState(call("player.previous") as JSONObject)

    suspend fun stopPlayer(): PlayerState = PlayerState(call("player.stop") as JSONObject)

    suspend fun retry(): PlayerState = PlayerState(call("player.retry") as JSONObject)

    suspend fun tracks(): List<Track> = call("player.tracks").asArray().map(::Track)

    /** [id] null switches that kind off (no subtitles). */
    suspend fun selectTrack(kind: String, id: Int?) {
        if (id != null) call("player.selectTrack", "kind" to kind, "id" to id) else call("player.selectTrack", "kind" to kind)
    }

    // MARK: Updates (the shared UpdateChecker and UpdateSignature, as on the Mac)

    /** Asks GitHub for the latest release of [repository] newer than [version] with an Android build. */
    suspend fun checkForUpdate(repository: String, version: String): UpdateInfo =
        UpdateInfo(call("update.check", "repository" to repository, "version" to version) as JSONObject)

    /** Throws unless [file] matches [signature] (the .sig file's text) under [publicKey]. */
    suspend fun verifyUpdate(file: String, signature: String, publicKey: String) {
        call("update.verify", "file" to file, "signature" to signature, "publicKey" to publicKey)
    }

    // MARK: Multiview (the shared MultiviewSession; tiles are players "tile0" to "tile3")

    /**
     * Opens multiview with [layout] tiles and [channel] (from [group]) in the first empty one. The
     * full-screen player stops first. Tiles chosen last time come back.
     */
    suspend fun startMultiview(layout: Int, channel: String?, group: String?): MultiviewState {
        val params = buildList<Pair<String, Any>> {
            add("layout" to layout)
            channel?.let { add("channel" to it) }
            group?.let { add("group" to it) }
        }
        return MultiviewState(call("multiview.start", *params.toTypedArray()) as JSONObject)
    }

    suspend fun multiviewLayout(layout: Int): MultiviewState = MultiviewState(call("multiview.layout", "layout" to layout) as JSONObject)

    suspend fun setTileChannel(tile: Int, channel: String, group: String): MultiviewState =
        MultiviewState(call("multiview.setChannel", "tile" to tile, "channel" to channel, "group" to group) as JSONObject)

    suspend fun clearTile(tile: Int): MultiviewState = MultiviewState(call("multiview.clearTile", "tile" to tile) as JSONObject)

    suspend fun focusTileAudio(tile: Int): MultiviewState = MultiviewState(call("multiview.focusAudio", "tile" to tile) as JSONObject)

    suspend fun retryTile(tile: Int): MultiviewState = MultiviewState(call("multiview.retry", "tile" to tile) as JSONObject)

    /** [provider] null: automatic. */
    suspend fun pinTileProvider(tile: Int, provider: String?): MultiviewState = MultiviewState(
        (if (provider != null) call("multiview.pinProvider", "tile" to tile, "provider" to provider)
        else call("multiview.pinProvider", "tile" to tile)) as JSONObject)

    /** Returns once every tile's stream is closed. */
    suspend fun stopMultiview(): MultiviewState = MultiviewState(call("multiview.stop") as JSONObject)

    /** An event from the engine, passed straight to the core (doesn't wait). */
    fun playerEvent(event: JSONObject) {
        nativePlayerEvent(event.toString().toByteArray())
    }

    /** Checks of this build (debug.icuChecks, debug.memory, debug.fetch), for tests. */
    suspend fun debug(method: String, vararg params: Pair<String, Any>): Any = call("debug.$method", *params)

    /**
     * Sends one request and returns its `result`. Runs on a background thread; the core answers
     * each request in one go (a whole channel list in one reply).
     */
    suspend fun call(method: String, vararg params: Pair<String, Any>): Any = withContext(Dispatchers.IO) {
        val request = JSONObject().put("method", method).put("params", JSONObject().apply {
            for ((key, value) in params) put(key, value)
        })
        val reply = JSONObject(String(nativeCall(request.toString().toByteArray())))
        if (reply.has("error")) throw CoreException(reply.getString("error"))
        reply.get("result")
    }

    private fun Any.asArray(): List<JSONObject> {
        val array = this as JSONArray
        return List(array.length()) { array.getJSONObject(it) }
    }

    private fun Any.asObject(): JSONObject = this as JSONObject

    @JvmStatic private external fun nativeStart(databasePath: ByteArray, cacheDir: ByteArray, listener: CoreListener): ByteArray?
    @JvmStatic private external fun nativeCall(request: ByteArray): ByteArray
    @JvmStatic private external fun nativePlayerEvent(event: ByteArray)
}

/** A failed request, with a message fit to show. */
class CoreException(message: String) : Exception(message)

/**
 * What the core calls back: events, and the saved logins (kept in [LoginVault]). Called from the
 * core's own threads. Text arrives as UTF-8 bytes (see cjni.h); method names and signatures are
 * looked up by the C side, so keep them as they are.
 */
class CoreListener(private val vault: LoginVault, private val emit: (BridgeEvent) -> Unit) {
    fun onEvent(json: ByteArray) {
        runCatching { emit(BridgeEvent(JSONObject(String(json)))) }
    }

    fun saveSecret(providerID: ByteArray, value: ByteArray): Boolean = vault.save(String(providerID), value)

    fun loadSecret(providerID: ByteArray): ByteArray? = vault.load(String(providerID))

    fun deleteSecret(providerID: ByteArray): Boolean = vault.delete(String(providerID))

    /** A command for a player engine, from the core's main actor (the UI thread). */
    fun onPlayerCommand(command: ByteArray): ByteArray = PlayerEngines.handle(String(command)).toByteArray()
}
