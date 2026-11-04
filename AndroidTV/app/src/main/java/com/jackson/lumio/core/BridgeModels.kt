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

data class Programme(val title: String, val start: Double, val stop: Double, val subtitle: String?, val summary: String?) {
    constructor(json: JSONObject) : this(
        title = json.getString("title"),
        start = json.getDouble("start"),
        stop = json.getDouble("stop"),
        subtitle = json.text("subtitle"),
        summary = json.text("summary"),
    )

    /** 0–1 through the programme at [now] (seconds since 1970). */
    fun progress(now: Double): Float =
        if (stop <= start) 0f else ((now - start) / (stop - start)).coerceIn(0.0, 1.0).toFloat()
}

/**
 * A change in the core. type: providers, live, guide, or sync (with provider, label, finished, error).
 */
data class BridgeEvent(
    val type: String,
    val provider: String?,
    val label: String?,
    val finished: Boolean,
    val error: String?,
) {
    constructor(json: JSONObject) : this(
        type = json.getString("type"),
        provider = json.text("provider"),
        label = json.text("label"),
        finished = json.optBoolean("finished", false),
        error = json.text("error"),
    )
}

// MARK: JSON helpers

/** The string at [key], or null when it's missing or JSON null. */
internal fun JSONObject.text(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null

internal fun JSONObject.number(key: String): Double? = if (has(key) && !isNull(key)) getDouble(key) else null

internal fun JSONArray.objects(): List<JSONObject> = List(length()) { getJSONObject(it) }

internal fun JSONArray.strings(): List<String> = List(length()) { getString(it) }
