package com.jackson.lumio.ui.player

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalView

/**
 * Keeps the TV awake while [on]: without it, the box's screensaver and sleep timer count a
 * channel being watched as the remote sitting idle. Off again when [on] turns false or the
 * screen leaves, so the guide and a paused movie still let the box sleep.
 */
@Composable
fun KeepScreenOn(on: Boolean) {
    val view = LocalView.current
    DisposableEffect(view, on) {
        view.keepScreenOn = on
        onDispose { view.keepScreenOn = false }
    }
}

/** Player phases (from the core) in which video is playing or on its way. */
val AwakePhases = setOf("connecting", "buffering", "playing", "reconnecting", "waitingForNetwork")
