package com.jackson.lumio.core

import android.app.Activity
import android.app.Application
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Bundle

/**
 * Tells the core when the network comes and goes and when the app leaves or returns to the
 * screen (the TV going to sleep, or the user switching apps), the Android side of the Mac's
 * NWPathMonitor and sleep/wake notifications. Playback uses them to wait for the network
 * instead of burning retries, and to stop streams while nobody is watching.
 */
class SystemMonitor(private val application: Application) {
    private var startedActivities = 0

    fun start() {
        val connectivity = application.getSystemService(ConnectivityManager::class.java)
        connectivity.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                LumioCore.systemEvent("network", capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET))
            }

            override fun onLost(network: Network) {
                LumioCore.systemEvent("network", false)
            }
        })
        application.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityStarted(activity: Activity) {
                if (startedActivities++ == 0) LumioCore.systemEvent("didWake")
            }

            override fun onActivityStopped(activity: Activity) {
                if (--startedActivities == 0) LumioCore.systemEvent("willSleep")
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityPaused(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        })
    }
}
