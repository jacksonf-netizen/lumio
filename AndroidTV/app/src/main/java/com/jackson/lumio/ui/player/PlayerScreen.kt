package com.jackson.lumio.ui.player

import android.view.KeyEvent as AndroidKeyEvent
import com.jackson.lumio.ui.common.LumioButton
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.produceState
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
import androidx.tv.material3.Text
import com.jackson.lumio.images.RemoteImage
import com.jackson.lumio.player.PlayerEngines
import com.jackson.lumio.ui.LumioColors
import com.jackson.lumio.ui.common.MenuAction
import com.jackson.lumio.ui.common.OptionsPanel
import com.jackson.lumio.ui.guide.PressTracker
import com.jackson.lumio.ui.vod.clock
import kotlinx.coroutines.delay

/**
 * Full-screen live TV. Up/down and CH+/CH- change channel (through the list playback started
 * from), number keys pick a channel by number, OK opens the channel list over the video (as in
 * TiviMate), Left or Info shows the info banner, the last-channel key goes back to the previous
 * channel, Right (or Menu) opens audio and subtitles, Back closes the player. For a movie or episode: OK pauses, left/right skip 10 s (rewind and fast-forward 30 s),
 * Down or Menu opens audio and subtitles, and Back closes (the core saves where it got to).
 */
@OptIn(UnstableApi::class)
@Composable
fun PlayerScreen(model: PlayerViewModel, onMultiview: (() -> Unit)? = null) {
    val state = model.state
    val focus = remember { FocusRequester() }
    val press = remember { PressTracker() }
    // Hold OK on live TV: multiview, audio and subtitles.
    var options by remember { mutableStateOf(false) }
    BackHandler(enabled = !options) {
        when {
            model.channelList != null -> model.closeChannels()
            model.tracks != null -> model.closeTracks()
            else -> model.close()
        }
    }
    LaunchedEffect(Unit) { focus.requestFocus() }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .focusRequester(focus)
            .focusable()
            .onPreviewKeyEvent { event ->
                if (state?.phase == "failed" || model.openError != null || model.tracks != null || options || model.channelList != null) return@onPreviewKeyEvent false
                val code = event.key.nativeKeyCode
                // Still opening: the keys wait (Back still closes).
                if (model.opening != null && code != AndroidKeyEvent.KEYCODE_BACK) return@onPreviewKeyEvent true
                if (state?.vod == null && (code == AndroidKeyEvent.KEYCODE_DPAD_CENTER || code == AndroidKeyEvent.KEYCODE_ENTER)) {
                    // Live TV: OK opens the channel list, Hold OK the options (on release, so it can't pick one).
                    when (press.ok(event.type == KeyEventType.KeyDown, event.nativeKeyEvent.repeatCount)) {
                        PressTracker.Result.Click -> model.openChannels()
                        PressTracker.Result.LongClick -> options = true
                        PressTracker.Result.None -> {}
                    }
                    return@onPreviewKeyEvent true
                }
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                if (state?.vod != null) {
                    // A movie or episode: pause, skip, audio and subtitles. No zapping.
                    when (event.key.nativeKeyCode) {
                        AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER, AndroidKeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                        AndroidKeyEvent.KEYCODE_MEDIA_PLAY, AndroidKeyEvent.KEYCODE_MEDIA_PAUSE -> model.togglePause()
                        AndroidKeyEvent.KEYCODE_DPAD_LEFT -> model.skip(-10.0)
                        AndroidKeyEvent.KEYCODE_DPAD_RIGHT -> model.skip(10.0)
                        AndroidKeyEvent.KEYCODE_MEDIA_REWIND -> model.skip(-30.0)
                        AndroidKeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> model.skip(30.0)
                        AndroidKeyEvent.KEYCODE_DPAD_UP, AndroidKeyEvent.KEYCODE_INFO -> model.showBanner()
                        AndroidKeyEvent.KEYCODE_DPAD_DOWN, AndroidKeyEvent.KEYCODE_MENU, AndroidKeyEvent.KEYCODE_CAPTIONS -> model.openTracks()
                        else -> return@onPreviewKeyEvent false
                    }
                    return@onPreviewKeyEvent true
                }
                when (code) {
                    AndroidKeyEvent.KEYCODE_DPAD_UP, AndroidKeyEvent.KEYCODE_CHANNEL_DOWN -> model.zap(-1)
                    AndroidKeyEvent.KEYCODE_DPAD_DOWN, AndroidKeyEvent.KEYCODE_CHANNEL_UP -> model.zap(1)
                    AndroidKeyEvent.KEYCODE_INFO, AndroidKeyEvent.KEYCODE_DPAD_LEFT -> model.showBanner()
                    AndroidKeyEvent.KEYCODE_LAST_CHANNEL, AndroidKeyEvent.KEYCODE_MEDIA_PREVIOUS -> model.previous()
                    AndroidKeyEvent.KEYCODE_DPAD_RIGHT, AndroidKeyEvent.KEYCODE_MENU, AndroidKeyEvent.KEYCODE_CAPTIONS -> model.openTracks()
                    in AndroidKeyEvent.KEYCODE_0..AndroidKeyEvent.KEYCODE_9 -> model.digit(code - AndroidKeyEvent.KEYCODE_0)
                    else -> return@onPreviewKeyEvent false
                }
                true
            },
    ) {
        Video()
        Status(model)
        if (state?.vod != null) {
            if (model.bannerVisible || state.phase == "paused" || model.seekTarget != null) VODControls(model)
        } else if (model.bannerVisible || state?.phase == "failed") Banner(model)
        TopRight(model)
        model.tracks?.let { TracksPanel(it, onSelect = model::selectTrack) }
        model.channelList?.let { list ->
            ChannelListPanel(list, playing = state?.channel?.id, onPick = model::pickChannel, onScroll = model::loadNowNextAround)
        }
        if (options) {
            OptionsPanel(
                title = state?.channel?.name ?: "Options",
                actions = buildList {
                    if (onMultiview != null) add(MenuAction("Multiview", run = onMultiview))
                    add(MenuAction("Audio and subtitles") { model.openTracks() })
                },
                onDismiss = { options = false },
                detail = if (onMultiview == null) ({
                    Text("This TV can only play one video at a time, so multiview isn't available.",
                        color = LumioColors.secondaryText, fontSize = 15.sp)
                }) else null,
            )
        }
    }
    // Focus comes back to the player when the tracks panel or the options close.
    val bare = model.tracks == null && !options && model.channelList == null
    LaunchedEffect(bare) { if (bare) runCatching { focus.requestFocus() } }
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
    model.openError?.let { reason ->
        OpenFailed(model, reason)
        return
    }
    val state = model.state
    // "Opening <channel>…" from the moment OK was pressed, until the core has answered.
    val text = model.opening ?: when (state?.phase) {
        null -> return
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
                Text(state?.message ?: model.error ?: "", color = LumioColors.secondaryText, fontSize = 17.sp)
                Spacer(Modifier.height(18.dp))
                LumioButton(onClick = model::retry, modifier = Modifier.focusRequester(retry)) { Text("Try again") }
            }
        }
    }
}

/** The core refused to open the channel or movie: why, and a Close button (Back works too). */
@Composable
private fun OpenFailed(model: PlayerViewModel, reason: String) {
    val close = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { close.requestFocus() } }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.background(Color(0xCC000000), RoundedCornerShape(12.dp)).padding(28.dp).width(640.dp),
        ) {
            Text("Couldn't open this", color = Color.White, fontSize = 24.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))
            Text(reason, color = LumioColors.secondaryText, fontSize = 17.sp)
            Spacer(Modifier.height(18.dp))
            LumioButton(onClick = model::close, modifier = Modifier.focusRequester(close)) { Text("Close") }
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

/** A movie's or episode's title, where it is, and how long it is, along the bottom. */
@Composable
private fun VODControls(model: PlayerViewModel) {
    val vod = model.state?.vod ?: return
    val engine = remember { PlayerEngines.engine("main") }
    // The position, read from the player twice a second while the controls show.
    val timeline by produceState(engine.timeline, engine) {
        while (true) {
            value = engine.timeline
            delay(500)
        }
    }
    val duration = timeline?.second
    val position = model.seekTarget ?: timeline?.first ?: 0.0
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        Column(
            Modifier
                .fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xE6000000))))
                .padding(start = 56.dp, end = 56.dp, top = 60.dp, bottom = 36.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (model.state?.phase == "paused") {
                    Text("Paused", color = Color.Black, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.background(Color.White, RoundedCornerShape(4.dp)).padding(horizontal = 8.dp, vertical = 2.dp))
                    Spacer(Modifier.width(12.dp))
                }
                Text(vod.title, color = Color.White, fontSize = 26.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            vod.subtitle?.let { Text(it, color = LumioColors.secondaryText, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            Spacer(Modifier.height(14.dp))
            Box(Modifier.fillMaxWidth().height(5.dp).clip(RoundedCornerShape(3.dp)).background(Color(0x55FFFFFF))) {
                val fraction = if (duration != null && duration > 0) (position / duration).toFloat().coerceIn(0f, 1f) else 0f
                Box(Modifier.fillMaxWidth(fraction).fillMaxHeight().background(LumioColors.accent))
            }
            Row(Modifier.fillMaxWidth().padding(top = 8.dp)) {
                Text(clock(position), color = Color.White, fontSize = 15.sp)
                Spacer(Modifier.weight(1f))
                Text("◀ ▶ skip 10 s   ·   OK pause   ·   ▼ audio and subtitles", color = LumioColors.secondaryText, fontSize = 13.sp)
                Spacer(Modifier.weight(1f))
                Text(duration?.let { "-" + clock(maxOf(0.0, it - position)) } ?: "", color = Color.White, fontSize = 15.sp)
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
