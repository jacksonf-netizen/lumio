package com.jackson.lumio.ui.player

import android.content.Context
import androidx.annotation.OptIn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.jackson.lumio.player.PlayerEngines

/**
 * Settings → Playback → Preview in Live TV: the guide plays the highlighted channel in a small
 * picture. It's the main player, small (a provider with one connection has no room for a second),
 * so OK carries on full screen without reconnecting and Back shrinks it again.
 */
object GuidePreview {
    private const val PREFERENCES = "guide"
    private const val KEY = "preview"

    var enabled by mutableStateOf(true)
        private set

    fun load(context: Context) {
        enabled = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getBoolean(KEY, true)
    }

    fun set(context: Context, on: Boolean) {
        enabled = on
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().putBoolean(KEY, on).apply()
    }
}

/**
 * The main player's picture. Full screen and the guide's preview each show one of these; the
 * newest takes the picture, and one that goes only lets go if it still has it.
 */
@OptIn(UnstableApi::class)
@Composable
fun MainVideo(modifier: Modifier) {
    val engine = remember { PlayerEngines.engine("main") }
    val link = remember { arrayOfNulls<(ExoPlayer?) -> Unit>(1) }
    AndroidView(
        factory = { context ->
            PlayerView(context).apply {
                useController = false
                resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                setShutterBackgroundColor(android.graphics.Color.BLACK)
                isFocusable = false
                val show: (ExoPlayer?) -> Unit = { player = it }
                link[0] = show
                engine.onPlayerChanged = show
            }
        },
        modifier = modifier,
        onRelease = { view -> view.player = null },
    )
    DisposableEffect(engine) { onDispose { if (engine.onPlayerChanged === link[0]) engine.onPlayerChanged = null } }
}
