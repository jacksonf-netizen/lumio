package com.jackson.lumio

import org.json.JSONObject

/**
 * The shared core (Shared/LumioCore), compiled from Swift into liblumiocore.so.
 *
 * Phase 0 (test build): one JSON call, written by hand. Phase 2 replaces it with swift-java and
 * real types. Calls block until the core answers, so make them off the main thread.
 */
object LumioCore {
    init {
        System.loadLibrary("lumiocore")
    }

    @JvmStatic
    private external fun nativeCall(request: String): String

    fun call(command: String, vararg fields: Pair<String, Any>): JSONObject {
        val request = JSONObject().put("command", command)
        for ((key, value) in fields) request.put(key, value)
        return JSONObject(nativeCall(request.toString()))
    }
}
