package com.jackson.lumio

import android.app.Application
import com.jackson.lumio.core.LumioCore
import com.jackson.lumio.core.SystemMonitor
import com.jackson.lumio.images.ImageLoader
import com.jackson.lumio.player.PlayerEngines

/** Starts the shared core once per process, on the main thread (it hooks into the main looper). */
class LumioApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        PlayerEngines.init(this)
        LumioCore.start(this)
        SystemMonitor(this).start()
        ImageLoader.init(this)
    }
}
