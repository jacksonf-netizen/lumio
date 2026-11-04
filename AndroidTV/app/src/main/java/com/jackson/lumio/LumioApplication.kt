package com.jackson.lumio

import android.app.Application
import com.jackson.lumio.core.LumioCore
import com.jackson.lumio.core.SystemMonitor
import com.jackson.lumio.images.ImageLoader

/** Starts the shared core once per process, on the main thread (it hooks into the main looper). */
class LumioApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        LumioCore.start(this)
        SystemMonitor(this).start()
        ImageLoader.init(this)
    }
}
