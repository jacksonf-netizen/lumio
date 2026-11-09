package com.jackson.lumio.ui

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * How big everything is drawn: text, rows, posters, the rail. One scale for the whole app, so a
 * change keeps every screen in proportion. Settings → Display changes it; it's kept on this TV
 * only (the Mac has its own window sizes).
 */
enum class DisplaySize(val title: String, val scale: Float) {
    Smaller("Smaller", 0.7f),
    Default("Default", 0.8f),
    Larger("Larger", 0.9f),
    Largest("Largest", 1f),
}

object DisplaySizes {
    private const val PREFERENCES = "display"
    private const val KEY = "size"

    /** The size in use; reading it in a composable redraws the app when it changes. */
    var current by mutableStateOf(DisplaySize.Default)
        private set

    fun load(context: Context) {
        val saved = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(KEY, null)
        current = DisplaySize.entries.firstOrNull { it.name == saved } ?: DisplaySize.Default
    }

    fun set(context: Context, size: DisplaySize) {
        current = size
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().putString(KEY, size.name).apply()
    }
}
