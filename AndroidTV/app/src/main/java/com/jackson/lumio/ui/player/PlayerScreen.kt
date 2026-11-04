package com.jackson.lumio.ui.player

import android.view.KeyEvent as AndroidKeyEvent
import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import androidx.tv.material3.Button
import androidx.tv.material3.Text
import com.jackson.lumio.images.RemoteImage
import com.jackson.lumio.player.PlayerEngines
import com.jackson.lumio.ui.LumioColors

/**
 * Full-screen live TV. Up/down and CH+/CH- change channel (through the list playback started
 * from), number keys pick a channel by number, OK shows the info banner, the last-channel key
 * goes back to the previous channel, Back closes the player.
 */
@OptIn(UnstableApi::class)
@Composable
fun PlayerScreen(model: PlayerViewModel) {
    val state = model.state
    val focus = remember { FocusRequester() }
    BackHandler { model.close() }
    LaunchedEffect(Unit) { focus.requestFocus() }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .focusRequester(focus)
            .focusable()
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown || state?.phase == "failed") return@onPreviewKeyEvent false
                when (val code = event.key.nativeKeyCode) {
                    AndroidKeyEvent.KEYCODE_DPAD_UP, AndroidKeyEvent.KEYCODE_CHANNEL_DOWN -> model.zap(-1)
                    AndroidKeyEvent.KEYCODE_DPAD_DOWN, AndroidKeyEvent.KEYCODE_CHANNEL_UP -> model.zap(1)
                    AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER, AndroidKeyEvent.KEYCODE_INFO -> model.showBanner()
                    AndroidKeyEvent.KEYCODE_LAST_CHANNEL, AndroidKeyEvent.KEYCODE_MEDIA_PREVIOUS -> model.previous()
                    in AndroidKeyEvent.KEYCODE_0..AndroidKeyEvent.KEYCODE_9 -> model.digit(code - AndroidKeyEvent.KEYCODE_0)
                    else -> return@onPreviewKeyEvent false
                }
                true
            },
    ) {
        Video()
        Status(model)
        if (model.bannerVisible || state?.phase == "failed") Banner(model)
        TopRight(model)
    }
}

@OptIn(UnstableApi::class)
@Composable
private fun Video() {
    val engine = remember { PlayerEngines.engine("main") }
    AndroidView(
        factory = { context ->
            PlayerView(context).apply {
                useController = false
                resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                setShutterBackgroundColor(android.graphics.Color.BLACK)
                isFocusable = false
            }
        },
        modifier = Modifier.fillMaxSize(),
        update = { view -> engine.onPlayerChanged = { view.player = it } },
    )
    DisposableEffect(Unit) { onDispose { engine.onPlayerChanged = null } }
}

/** What's happening, when it isn't simply playing. */
@Composable
private fun Status(model: PlayerViewModel) {
    val state = model.state ?: return
    val text = when (state.phase) {
        "connecting", "buffering" -> "Opening…"
        "reconnecting" -> "Reconnecting…"
        "waitingForNetwork" -> "Waiting for the network…"
        "suspended" -> "Paused while the TV sleeps"
        "preempted" -> "Stopped: another player took the connection"
        "failed" -> null
        else -> return
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        if (text != null) {
            Text(text, color = Color.White, fontSize = 22.sp,
                modifier = Modifier.background(Color(0x99000000), RoundedCornerShape(10.dp)).padding(horizontal = 22.dp, vertical = 12.dp))
        } else {
            val retry = remember { FocusRequester() }
            LaunchedEffect(Unit) { runCatching { retry.requestFocus() } }
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.background(Color(0xCC000000), RoundedCornerShape(12.dp)).padding(28.dp).width(640.dp),
            ) {
                Text("Couldn't play this channel", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                Text(state.message ?: model.error ?: "", color = LumioColors.secondaryText, fontSize = 17.sp)
                Spacer(Modifier.height(18.dp))
                Button(onClick = model::retry, modifier = Modifier.focusRequester(retry)) { Text("Try again") }
            }
        }
    }
}

/** Channel, provider and what's on, along the bottom. */
@Composable
private fun Banner(model: PlayerViewModel) {
    val channel = model.state?.channel ?: return
    val now = model.nowNext?.now
    val next = model.nowNext?.next
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(20.dp),
            modifier = Modifier
                .fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xE6000000))))
                .padding(start = 56.dp, end = 56.dp, top = 60.dp, bottom = 40.dp),
        ) {
            Text(channel.number?.toString() ?: "", color = Color.White, fontSize = 34.sp, fontWeight = FontWeight.SemiBold)
            RemoteImage(channel.logo, 72.dp)
            Column(Modifier.weight(1f)) {
                Text(channel.name, color = Color.White, fontSize = 26.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                model.state?.provider?.let { Text(it, color = LumioColors.secondaryText, fontSize = 15.sp) }
                if (now != null) {
                    Spacer(Modifier.height(8.dp))
                    Text("Now: ${now.title}", color = Color.White, fontSize = 18.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    val seconds = System.currentTimeMillis() / 1000.0
                    Box(Modifier.padding(vertical = 6.dp).width(360.dp).height(4.dp).clip(RoundedCornerShape(2.dp)).background(Color(0x55FFFFFF))) {
                        Box(Modifier.fillMaxWidth(now.progress(seconds)).fillMaxHeight().background(LumioColors.accent))
                    }
                }
                next?.let { Text("Next: ${it.title}", color = LumioColors.secondaryText, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            }
        }
    }
}

/** Digits being typed, and notices such as "Now playing from Provider B". */
@Composable
private fun TopRight(model: PlayerViewModel) {
    val text = model.digits.ifEmpty { null } ?: model.state?.notice ?: return
    Box(Modifier.fillMaxSize().padding(40.dp), contentAlignment = Alignment.TopEnd) {
        Text(text, color = Color.White, fontSize = if (model.digits.isNotEmpty()) 40.sp else 18.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.background(Color(0x99000000), RoundedCornerShape(10.dp)).padding(horizontal = 18.dp, vertical = 10.dp))
    }
}
