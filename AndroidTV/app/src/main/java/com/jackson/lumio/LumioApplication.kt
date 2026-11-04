package com.jackson.lumio

import android.app.Application
import com.jackson.lumio.core.LumioCore

/** Starts the shared core once per process, on the main thread (it hooks into the main looper). */
class LumioApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        LumioCore.start(this)
    }
}
