package com.jackson.lumio.ui.multiview

import android.view.KeyEvent as AndroidKeyEvent
import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import androidx.tv.material3.Border
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import com.jackson.lumio.core.MultiviewState
import com.jackson.lumio.core.Tile
import com.jackson.lumio.player.PlayerEngines
import com.jackson.lumio.ui.LumioColors
import com.jackson.lumio.ui.common.MenuAction
import com.jackson.lumio.ui.common.OptionsPanel
import com.jackson.lumio.ui.guide.PressTracker
import com.jackson.lumio.ui.live.LiveTvScreen
import kotlinx.coroutines.delay

/**
 * Multiview, full screen: 2 tiles side by side, 3 as one large tile with two beside it, or 4 in a
 * grid. The arrows move between tiles and the highlighted tile is the one heard. OK opens a tile's
 * options (an empty tile goes straight to choosing a channel); Back watches the highlighted tile
 * full screen, as Esc does on the Mac.
 */
@Composable
fun MultiviewScreen(
    model: MultiviewViewModel,
    onFullScreen: (channel: String, group: String) -> Unit,
    onClose: () -> Unit,
) {
    val state = model.state
    var panel by remember { mutableStateOf<Int?>(null) }
    var picking by remember { mutableStateOf<Int?>(null) }
    var hint by remember { mutableStateOf(true) }
    val tileFocus = remember { List(4) { FocusRequester() } }
    // The highlighted tile, and the one the picker or a panel was opened from. Focus goes back to
    // the latter: while the picker closes, Compose can briefly hand the highlight to another tile.
    var focused by remember { mutableStateOf(state?.audioTile ?: 0) }
    var returnTo by remember { mutableStateOf(state?.audioTile ?: 0) }

    fun leave() {
        val tile = state?.tiles?.getOrNull(focused)?.takeIf { it.channel != null }
            ?: state?.tiles?.firstOrNull { it.channel != null }
        val channel = tile?.channel
        if (channel != null) onFullScreen(channel.id, tile.group ?: "all") else onClose()
    }
    BackHandler(enabled = panel == null && picking == null) { leave() }
    LaunchedEffect(Unit) {
        delay(6000)
        hint = false
    }
    // Focus starts on (and comes back to) a tile, also after the layout changes (the tiles are
    // laid out again, so the highlighted one may have gone).
    LaunchedEffect(panel == null && picking == null, state != null, state?.layout) {
        if (panel == null && picking == null && state != null) {
            delay(50)
            runCatching { tileFocus[returnTo.coerceIn(0, state.layout - 1)].requestFocus() }
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            // The remote stays in multiview; the screens underneath can't take the highlight.
            .focusProperties { onExit = { cancelFocusChange() } }
            .focusGroup(),
    ) {
        if (state != null) {
            Grid(state.layout, Modifier.align(Alignment.Center)) { index, modifier ->
                val tile = state.tiles.getOrNull(index)
                TileView(
                    index = index,
                    tile = tile,
                    heard = state.audioTile == index,
                    // Covered tiles can't take the highlight.
                    modifier = modifier
                        .focusRequester(tileFocus[index])
                        .focusProperties { canFocus = panel == null && picking == null },
                    onFocused = {
                        focused = index
                        model.focusAudio(index)
                    },
                    onClick = {
                        returnTo = index
                        if (tile?.channel == null) picking = index else panel = index
                    },
                    onLongClick = {
                        returnTo = index
                        panel = index
                    },
                )
            }
            state.warning?.let { Warning(it) }
        }
        if (hint && panel == null && picking == null) Hint()

        val panelTile = panel?.let { state?.tiles?.getOrNull(it) }
        if (panel != null && state != null) {
            val index = panel!!
            OptionsPanel(
                title = panelTile?.channel?.name ?: "Tile ${index + 1}",
                actions = tileActions(model, state, index, panelTile,
                    pick = { picking = index },
                    fullScreen = { channel, group -> onFullScreen(channel, group) },
                    close = onClose),
                onDismiss = { panel = null },
                detail = panelTile?.provider?.let { provider -> { Text("From $provider", color = LumioColors.secondaryText, fontSize = 15.sp) } },
            )
        }
        picking?.let { index ->
            Picker(index, onPick = { channel, group ->
                model.setChannel(index, channel, group)
                picking = null
            }, onDismiss = { picking = null })
        }
    }
}

/** What OK (or Hold OK) on a tile offers. */
private fun tileActions(
    model: MultiviewViewModel,
    state: MultiviewState,
    index: Int,
    tile: Tile?,
    pick: () -> Unit,
    fullScreen: (String, String) -> Unit,
    close: () -> Unit,
): List<MenuAction> = buildList {
    val channel = tile?.channel
    if (channel != null) {
        add(MenuAction("Watch full screen") { fullScreen(channel.id, tile.group ?: "all") })
        add(MenuAction("Change channel", run = pick))
        if (tile.phase == "failed") add(MenuAction("Try again") { model.retry(index) })
        if (tile.providers.size > 1) {
            add(MenuAction("Provider: automatic", selected = tile.pinned == null) { model.pin(index, null) })
            for (provider in tile.providers) {
                add(MenuAction("Provider: ${provider.name}", selected = tile.pinned == provider.id) { model.pin(index, provider.id) })
            }
        }
        add(MenuAction("Remove from multiview") { model.clearTile(index) })
    } else {
        add(MenuAction("Choose a channel", run = pick))
    }
    for (layout in model.layouts) {
        add(MenuAction("$layout tiles", selected = state.layout == layout) { model.setLayout(layout) })
    }
    add(MenuAction("Close multiview", run = close))
}

/** Lays out [count] tiles; [tile] draws tile `index` with the size modifier it's given. */
@Composable
private fun Grid(count: Int, modifier: Modifier, tile: @Composable (Int, Modifier) -> Unit) {
    val gap = Modifier.padding(3.dp)
    when (count) {
        2 -> Row(modifier.fillMaxWidth().aspectRatio(32f / 9f)) {
            tile(0, cell(gap))
            tile(1, cell(gap))
        }
        // One large tile and two stacked beside it, all 16:9: the large one is twice as wide.
        3 -> Row(modifier.fillMaxWidth().aspectRatio(8f / 3f)) {
            tile(0, cell(gap, weight = 2f))
            Column(Modifier.weight(1f).fillMaxHeight()) {
                tile(1, cell(gap))
                tile(2, cell(gap))
            }
        }
        else -> Column(modifier.fillMaxSize()) {
            Row(Modifier.weight(1f).fillMaxWidth()) {
                tile(0, cell(gap))
                tile(1, cell(gap))
            }
            Row(Modifier.weight(1f).fillMaxWidth()) {
                tile(2, cell(gap))
                tile(3, cell(gap))
            }
        }
    }
}

private fun RowScope.cell(gap: Modifier, weight: Float = 1f) = Modifier.weight(weight).fillMaxHeight().then(gap)

private fun ColumnScope.cell(gap: Modifier) = Modifier.weight(1f).fillMaxWidth().then(gap)

@OptIn(UnstableApi::class)
@Composable
private fun TileView(
    index: Int,
    tile: Tile?,
    heard: Boolean,
    modifier: Modifier,
    onFocused: () -> Unit,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
) {
    var isFocused by remember { mutableStateOf(false) }
    // OK acts on release, so the release can't also pick the first choice of the panel it opens.
    val press = remember { PressTracker() }
    Surface(
        onClick = {},
        shape = ClickableSurfaceDefaults.shape(RectangleShape),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f),
        colors = ClickableSurfaceDefaults.colors(containerColor = Color(0xFF0B0B0E), focusedContainerColor = Color(0xFF0B0B0E)),
        border = ClickableSurfaceDefaults.border(focusedBorder = Border(BorderStroke(4.dp, LumioColors.accent))),
        modifier = modifier
            .onFocusChanged {
                if (it.isFocused && !isFocused) onFocused()
                isFocused = it.isFocused
            }
            .onPreviewKeyEvent { event ->
                val code = event.key.nativeKeyCode
                if (code != AndroidKeyEvent.KEYCODE_DPAD_CENTER && code != AndroidKeyEvent.KEYCODE_ENTER) return@onPreviewKeyEvent false
                when (press.ok(event.type == KeyEventType.KeyDown, event.nativeKeyEvent.repeatCount)) {
                    PressTracker.Result.Click -> onClick()
                    PressTracker.Result.LongClick -> onLongClick()
                    PressTracker.Result.None -> {}
                }
                true
            },
    ) {
        Box(Modifier.fillMaxSize().padding(4.dp)) {
            // Always there, so the player keeps its surface while channels change.
            TileVideo(index)
            val channel = tile?.channel
            // A stopped player keeps showing its last picture; cover it.
            if (channel == null || tile.phase in setOf("idle", "failed", "preempted", "ended")) {
                Box(Modifier.fillMaxSize().background(Color(0xFF0B0B0E)))
            }
            if (channel == null) {
                Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("+", color = Color.White, fontSize = 40.sp)
                    Text("Choose a channel", color = LumioColors.secondaryText, fontSize = 16.sp)
                }
            } else {
                TileStatus(tile, Modifier.align(Alignment.Center))
                if (isFocused || tile.phase == "failed") {
                    Column(
                        Modifier
                            .align(Alignment.BottomStart)
                            .fillMaxWidth()
                            .background(Brush.verticalGradient(listOf(Color.Transparent, Color(0xCC000000))))
                            .padding(start = 14.dp, end = 14.dp, top = 24.dp, bottom = 10.dp),
                    ) {
                        Text(listOfNotNull(channel.number?.toString(), channel.name).joinToString("  "), color = Color.White,
                            fontSize = 17.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        tile.provider?.let { Text(it, color = LumioColors.secondaryText, fontSize = 13.sp, maxLines = 1) }
                    }
                }
                if (heard) {
                    Text("Sound", color = Color.Black, fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.align(Alignment.TopStart).padding(10.dp)
                            .background(Color.White, RoundedCornerShape(4.dp)).padding(horizontal = 6.dp, vertical = 1.dp))
                }
            }
        }
    }
}

/** Opening, reconnecting, or why it failed. Nothing while it plays. */
@Composable
private fun TileStatus(tile: Tile, modifier: Modifier) {
    val text = when (tile.phase) {
        "connecting", "buffering" -> "Opening…"
        "reconnecting" -> "Reconnecting…"
        "waitingForNetwork" -> "Waiting for the network…"
        "suspended" -> "Paused while the TV sleeps"
        "preempted" -> "Stopped: another player took the connection"
        "failed" -> tile.message ?: "Couldn't play this channel"
        "idle" -> if (tile.providerID == null) "No free connection" else return
        else -> return
    }
    Text(
        text, color = Color.White, fontSize = 15.sp, textAlign = TextAlign.Center,
        modifier = modifier.padding(16.dp).widthIn(max = 420.dp)
            .background(Color(0xAA000000), RoundedCornerShape(8.dp)).padding(horizontal = 14.dp, vertical = 8.dp),
    )
}

@OptIn(UnstableApi::class)
@Composable
private fun TileVideo(index: Int) {
    val engine = remember(index) { PlayerEngines.engine("tile$index") }
    val link = remember { arrayOfNulls<(ExoPlayer?) -> Unit>(1) }
    AndroidView(
        factory = { context ->
            PlayerView(context).apply {
                useController = false
                resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                setShutterBackgroundColor(android.graphics.Color.TRANSPARENT)
                isFocusable = false
            }
        },
        modifier = Modifier.fillMaxSize(),
        update = { view ->
            if (link[0] == null) {
                val show: (ExoPlayer?) -> Unit = { view.player = it }
                link[0] = show
                engine.onPlayerChanged = show
            }
        },
    )
    // Only unhook this view's own link: when the layout changes, the new view for this tile has
    // already hooked itself up by the time the old one goes.
    DisposableEffect(engine) { onDispose { if (engine.onPlayerChanged === link[0]) engine.onPlayerChanged = null } }
}

@Composable
private fun Warning(text: String) {
    Box(Modifier.fillMaxWidth().padding(top = 24.dp), contentAlignment = Alignment.TopCenter) {
        Text(text, color = Color.White, fontSize = 16.sp,
            modifier = Modifier.widthIn(max = 900.dp).background(Color(0xE6332200), RoundedCornerShape(10.dp))
                .padding(horizontal = 18.dp, vertical = 10.dp))
    }
}

@Composable
private fun Hint() {
    Box(Modifier.fillMaxSize().padding(bottom = 28.dp), contentAlignment = Alignment.BottomCenter) {
        Text("Arrows: choose the tile you hear   ·   OK: tile options   ·   Back: watch it full screen",
            color = Color.White, fontSize = 15.sp,
            modifier = Modifier.background(Color(0xB3000000), RoundedCornerShape(10.dp)).padding(horizontal = 18.dp, vertical = 10.dp))
    }
}

/** Live TV's groups and channels, over the tiles: OK picks a channel, Back closes. */
@Composable
private fun Picker(tile: Int, onPick: (channel: String, group: String) -> Unit, onDismiss: () -> Unit) {
    BackHandler(onBack = onDismiss)
    val focus = remember { FocusRequester() }
    var hasFocus by remember { mutableStateOf(false) }
    // The channel list takes the highlight; if the group has no channels, the group list does.
    LaunchedEffect(Unit) {
        delay(500)
        if (!hasFocus) runCatching { focus.requestFocus() }
    }
    Column(
        Modifier
            .fillMaxSize()
            .background(LumioColors.background)
            .onFocusChanged { hasFocus = it.hasFocus }
            .focusRequester(focus)
            .focusProperties { onExit = { cancelFocusChange() } }
            .focusGroup(),
    ) {
        Text("Choose a channel for tile ${tile + 1}", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(start = 48.dp, top = 28.dp))
        Spacer(Modifier.height(4.dp))
        Box(Modifier.weight(1f).fillMaxWidth()) {
            LiveTvScreen(onPlay = onPick, playerShowing = false, startOnChannels = true)
        }
    }
}
