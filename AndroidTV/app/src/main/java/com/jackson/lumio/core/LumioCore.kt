package com.jackson.lumio.core

import android.content.Context
import android.util.Log
import kotlinx.coroutines.Dispatchers
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
}
