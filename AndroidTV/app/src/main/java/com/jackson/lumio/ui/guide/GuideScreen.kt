package com.jackson.lumio.ui.guide

import android.view.KeyEvent as AndroidKeyEvent
import com.jackson.lumio.ui.common.LumioButton
import androidx.activity.compose.BackHandler
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.Text
import com.jackson.lumio.core.Channel
import com.jackson.lumio.core.Programme
import com.jackson.lumio.images.RemoteImage
import com.jackson.lumio.ui.LumioColors
import com.jackson.lumio.ui.common.MenuAction
import com.jackson.lumio.ui.common.OptionsPanel
import java.util.Calendar
import java.util.Date
import kotlin.math.floor

private val ChannelColumn = 210.dp
private val RowHeight = 54.dp
/** Width of one minute of the grid; the screen's width sets how many hours show. */
private const val DP_PER_MINUTE = 5.5f

/** What a panel over the guide shows: Hold OK's options, a programme's details, or the group picker. */
private data class Panel(val title: String, val actions: List<MenuAction>, val programme: Programme? = null)

/**
 * The programme guide: channels down the left, time across, the highlighted programme's details
 * on top. The grid is one focusable box that moves its own highlight (left/right through
 * programmes, up/down through channels at the same time), which keeps the remote quick on the
 * onn HD stick: no per-programme focus to search through.
 *
 * Keys: OK watches what's on (or shows a later programme's details), Hold OK or Menu opens the
 * channel's options, CH+/CH- page, rewind and fast-forward go a day back or on, digits jump to a
 * channel number, Back returns to now (and then to the sidebar).
 */
@Composable
fun GuideScreen(
    scope: GuideScope,
    onPlay: (channel: String, group: String) -> Unit,
    playerShowing: Boolean,
    /** The channel the player is on, so closing the player brings the highlight to it. */
    playingChannel: String?,
    /** The list emptied while the grid had the remote (Recents cleared): the remote goes back to the sidebar. */
    onEmptied: () -> Unit = {},
) {
    val model: GuideViewModel = viewModel(key = "guide-${scope.name}") { GuideViewModel(scope) }
    val gridFocus = remember { FocusRequester() }
    var gridFocused by remember { mutableStateOf(false) }
    var panel by remember { mutableStateOf<Panel?>(null) }
    var played by remember { mutableStateOf(false) }
    val press = remember { PressTracker() }
    val listState = rememberLazyListState()
    val context = LocalContext.current
    val timeFormat = remember { android.text.format.DateFormat.getTimeFormat(context) }

    LaunchedEffect(playerShowing) {
        if (!playerShowing && played) {
            playingChannel?.let(model::moveTo)
            runCatching { gridFocus.requestFocus() }
        }
    }
    // When the list empties under the remote (the grid goes, and the remote with it), the remote goes
    // to the sidebar. Removing the grid may or may not report its focus lost, so both cases count.
    var lostWithList by remember { mutableStateOf(false) }
    LaunchedEffect(model.channels.isEmpty(), lostWithList) {
        if (model.channels.isEmpty() && (gridFocused || lostWithList)) {
            gridFocused = false
            lostWithList = false
            withFrameNanos { } // after the grid has gone
            onEmptied()
        }
    }
    // Closing a panel gives the remote back to the grid.
    var hadPanel by remember { mutableStateOf(false) }
    LaunchedEffect(panel == null) {
        if (panel != null) hadPanel = true
        else if (hadPanel) {
            hadPanel = false
            runCatching { gridFocus.requestFocus() }
        }
    }
    BackHandler(enabled = gridFocused && panel == null && !model.atNow) { model.jumpToNow() }

    fun play(channel: Channel) {
        played = true
        onPlay(channel.id, model.groupID)
    }

    fun options(channel: Channel, programme: Programme?) {
        val index = model.channels.indexOfFirst { it.id == channel.id }
        val actions = buildList {
            add(MenuAction("Watch ${channel.name}") { play(channel) })
            add(MenuAction(if (channel.favorite) "Remove from Favorites" else "Add to Favorites") { model.toggleFavorite(channel) })
            when (scope) {
                GuideScope.Favorites -> {
                    if (index > 0) {
                        add(MenuAction("Move up") { model.moveFavorite(channel, index - 1) })
                        add(MenuAction("Move to top") { model.moveFavorite(channel, 0) })
                    }
                    if (index < model.channels.size - 1) {
                        add(MenuAction("Move down") { model.moveFavorite(channel, index + 1) })
                        add(MenuAction("Move to bottom") { model.moveFavorite(channel, model.channels.size) })
                    }
                }
                GuideScope.Recents -> {
                    add(MenuAction("Remove from Recently Watched") { model.removeRecent(channel) })
                    add(MenuAction("Clear Recently Watched…") {
                        panel = Panel("Clear Recently Watched?", listOf(
                            MenuAction("Clear") { model.clearRecents() },
                            MenuAction("Cancel") {},
                        ))
                    })
                }
                GuideScope.All -> {}
            }
            if (!model.atNow) add(MenuAction("Back to now") { model.jumpToNow() })
        }
        panel = Panel(programme?.title ?: channel.name, actions, programme)
    }

    fun activate() {
        val channel = model.selectedChannel ?: return
        val programme = model.selectedCell?.programme
        // What's on now plays; a programme that's over or still to come shows its details.
        if (programme == null || programme.isOn(model.now)) play(channel) else options(channel, programme)
    }

    Box(Modifier.fillMaxSize()) {
        // Coming in from the sidebar, the remote lands on the channels, not the Group button above them.
        Column(Modifier.fillMaxSize().focusRestorer(gridFocus).focusGroup()) {
            val empty = model.channels.isEmpty()
            if (!empty) Details(model.selectedChannel, model.selectedCell, model.now, timeFormat)
            Toolbar(model, showHints = !empty, onPickGroup = {
                panel = Panel("Group", model.groups.map { group ->
                    MenuAction(group.name, selected = group.id == model.groupID) { model.selectGroup(group.id) }
                })
            })
            when {
                model.message != null && model.channels.isEmpty() ->
                    Message(model.message!!, LumioColors.error)
                model.loaded && model.channels.isEmpty() -> Message(emptyText(scope), LumioColors.secondaryText)
                else -> BoxWithConstraints(
                    Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .focusRequester(gridFocus)
                        .onFocusChanged {
                            if (!it.isFocused && gridFocused && model.channels.isEmpty()) lostWithList = true
                            gridFocused = it.isFocused
                        }
                        .focusable()
                        .onPreviewKeyEvent { event ->
                            val code = event.key.nativeKeyCode
                            val down = event.type == KeyEventType.KeyDown
                            if (code == AndroidKeyEvent.KEYCODE_DPAD_CENTER || code == AndroidKeyEvent.KEYCODE_ENTER ||
                                code == AndroidKeyEvent.KEYCODE_NUMPAD_ENTER
                            ) {
                                // Hold OK opens the options when it's let go, so the release can't
                                // also pick the panel's first choice.
                                when (press.ok(down, event.nativeKeyEvent.repeatCount)) {
                                    PressTracker.Result.Click -> activate()
                                    PressTracker.Result.LongClick -> model.selectedChannel?.let { options(it, model.selectedCell?.programme) }
                                    PressTracker.Result.None -> {}
                                }
                                return@onPreviewKeyEvent true
                            }
                            if (!down) return@onPreviewKeyEvent false
                            val page = maxOf(1, listState.layoutInfo.visibleItemsInfo.size - 1)
                            when (code) {
                                AndroidKeyEvent.KEYCODE_DPAD_UP -> if (model.cursor.row == 0) return@onPreviewKeyEvent false else model.move(-1)
                                AndroidKeyEvent.KEYCODE_DPAD_DOWN -> model.move(1)
                                AndroidKeyEvent.KEYCODE_DPAD_LEFT -> model.left()
                                AndroidKeyEvent.KEYCODE_DPAD_RIGHT -> model.right()
                                AndroidKeyEvent.KEYCODE_CHANNEL_UP, AndroidKeyEvent.KEYCODE_PAGE_DOWN -> model.move(page)
                                AndroidKeyEvent.KEYCODE_CHANNEL_DOWN, AndroidKeyEvent.KEYCODE_PAGE_UP -> model.move(-page)
                                AndroidKeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> model.day(1)
                                AndroidKeyEvent.KEYCODE_MEDIA_REWIND -> model.day(-1)
                                AndroidKeyEvent.KEYCODE_MENU, AndroidKeyEvent.KEYCODE_INFO ->
                                    model.selectedChannel?.let { options(it, model.selectedCell?.programme) }
                                in AndroidKeyEvent.KEYCODE_0..AndroidKeyEvent.KEYCODE_9 -> model.digit(code - AndroidKeyEvent.KEYCODE_0)
                                else -> return@onPreviewKeyEvent false
                            }
                            true
                        },
                ) {
                    val timeline = maxWidth - ChannelColumn
                    // Whole half hours that fit, at least an hour.
                    val minutes = maxOf(60, (floor(timeline.value / DP_PER_MINUTE / 30) * 30).toInt())
                    LaunchedEffect(minutes) { model.useWindow(minutes * 60.0) }
                    Grid(model, listState, timeline, gridFocused, timeFormat)
                }
            }
        }
        if (model.digits.isNotEmpty()) {
            Text(model.digits, color = Color.White, fontSize = 40.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.align(Alignment.TopEnd).padding(32.dp)
                    .background(Color(0xCC000000), RoundedCornerShape(10.dp)).padding(horizontal = 18.dp, vertical = 8.dp))
        }
        panel?.let { shown ->
            // A panel opened from another (Clear's confirmation) starts afresh, focus included.
            key(shown) {
                OptionsPanel(shown.title, shown.actions, onDismiss = { if (panel === shown) panel = null },
                    detail = shown.programme?.let { programme -> { ProgrammeDetail(programme, model.now, timeFormat) } })
            }
        }
    }
}

private fun emptyText(scope: GuideScope) = when (scope) {
    GuideScope.Favorites -> "No favorite channels yet. Hold OK on a channel in Live TV and choose Add to Favorites."
    GuideScope.Recents -> "Nothing watched yet. Channels you watch appear here, most recent first."
    GuideScope.All -> "No channels yet. They appear here once your provider has loaded."
}

@Composable
private fun Message(text: String, color: Color) {
    Text(text, color = color, fontSize = 18.sp, modifier = Modifier.padding(24.dp))
}

/** The group picker (Guide) or the list's name (Favorites, Recents). */
@Composable
private fun Toolbar(model: GuideViewModel, showHints: Boolean, onPickGroup: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, top = if (showHints) 6.dp else 32.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        when (model.scope) {
            GuideScope.All -> LumioButton(onClick = onPickGroup) {
                Text("Group: ${model.groups.firstOrNull { it.id == model.groupID }?.name ?: "All"}", maxLines = 1)
            }
            GuideScope.Favorites -> Text("Favorites", fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
            GuideScope.Recents -> Text("Recently Watched", fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.weight(1f))
        if (showHints) Text("Hold OK for options  ·  ◀◀ ▶▶ change day", color = LumioColors.secondaryText, fontSize = 13.sp)
    }
}

/** The highlighted programme, above the grid. */
@Composable
private fun Details(channel: Channel?, cell: GuideCell?, now: Double, timeFormat: java.text.DateFormat) {
    Column(Modifier.fillMaxWidth().height(150.dp).padding(start = 24.dp, end = 24.dp, top = 22.dp)) {
        if (channel == null) return@Column
        Text(listOfNotNull(channel.number?.toString(), channel.name).joinToString("  "),
            color = LumioColors.secondaryText, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        val programme = cell?.programme
        if (programme == null) {
            Text(if (cell == null && channel.epg != null) "Loading the guide…" else "No guide information",
                fontSize = 24.sp, color = LumioColors.secondaryText, modifier = Modifier.padding(top = 4.dp))
            return@Column
        }
        ProgrammeDetail(programme, now, timeFormat, large = true)
    }
}

@Composable
private fun ProgrammeDetail(programme: Programme, now: Double, timeFormat: java.text.DateFormat, large: Boolean = false) {
    Column {
        if (large) {
            Text(programme.title, fontSize = 26.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        val facts = listOfNotNull(timeText(programme, now, timeFormat), programme.episode, programme.category)
        Text(facts.joinToString("  ·  "), color = if (programme.isOn(now)) LumioColors.accent else LumioColors.secondaryText,
            fontSize = 15.sp, modifier = Modifier.padding(top = 2.dp))
        val about = listOfNotNull(programme.subtitle, programme.summary).joinToString(". ")
        if (about.isNotEmpty()) {
            Text(about, color = LumioColors.secondaryText, fontSize = 15.sp, maxLines = if (large) 2 else 10,
                overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 6.dp))
        }
    }
}

/** "18:00 – 19:00, 25 min left", "Tomorrow 09:00 – 10:00, in 14 h 5 min", or "Ended". */
private fun timeText(programme: Programme, now: Double, format: java.text.DateFormat): String {
    val range = "${dayPrefix(programme.start, now)}${format.format(date(programme.start))} – ${format.format(date(programme.stop))}"
    return when {
        programme.isOn(now) -> "$range, ${duration(programme.stop - now)} left"
        programme.start > now -> "$range, in ${duration(programme.start - now)}"
        else -> "$range, ended"
    }
}

private fun date(seconds: Double) = Date((seconds * 1000).toLong())

private fun duration(seconds: Double): String {
    val minutes = maxOf(1, (seconds / 60).toInt())
    return when {
        minutes < 60 -> "$minutes min"
        minutes % 60 == 0 -> "${minutes / 60} h"
        else -> "${minutes / 60} h ${minutes % 60} min"
    }
}

/** "", "Tomorrow ", "Yesterday " or a weekday and date, for [seconds] seen at [now]. */
private fun dayPrefix(seconds: Double, now: Double): String {
    val days = dayNumber(seconds) - dayNumber(now)
    return when (days) {
        0 -> ""
        1 -> "Tomorrow "
        -1 -> "Yesterday "
        else -> java.text.SimpleDateFormat("EEE d MMM ", java.util.Locale.getDefault()).format(date(seconds))
    }
}

private fun dayNumber(seconds: Double): Int {
    val calendar = Calendar.getInstance().apply { time = date(seconds) }
    return calendar.get(Calendar.YEAR) * 400 + calendar.get(Calendar.DAY_OF_YEAR)
}

@Composable
private fun Grid(
    model: GuideViewModel,
    listState: androidx.compose.foundation.lazy.LazyListState,
    timeline: Dp,
    focused: Boolean,
    timeFormat: java.text.DateFormat,
) {
    val cursor = model.cursor
    val window = model.window
    val dpPerSecond = timeline.value / window.toFloat()

    // Keeps the highlighted row on screen, a row in from the edge.
    LaunchedEffect(cursor.row, model.channels.size) {
        val info = listState.layoutInfo
        val count = maxOf(1, info.visibleItemsInfo.count { it.offset >= 0 && it.offset + it.size <= info.viewportEndOffset })
        val first = listState.firstVisibleItemIndex
        when {
            cursor.row < first + 1 -> listState.scrollToItem(maxOf(0, cursor.row - 1))
            cursor.row > first + count - 2 -> listState.scrollToItem(maxOf(0, cursor.row - count + 2))
        }
    }
    LaunchedEffect(listState) {
        snapshotFlow { listState.firstVisibleItemIndex..(listState.firstVisibleItemIndex + listState.layoutInfo.visibleItemsInfo.size) }
            .collect(model::showingRows)
    }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            TimeHeader(cursor.windowStart, window, model.now, dpPerSecond, timeFormat)
            LazyColumn(state = listState, userScrollEnabled = false, modifier = Modifier.fillMaxSize()) {
                itemsIndexed(model.channels, key = { _, channel -> channel.id }) { row, channel ->
                    val programmes = channel.epg?.let { model.programmes(it, cursor.windowStart, cursor.windowStart + window) }
                    GuideRow(
                        channel = channel,
                        programmes = if (channel.epg == null) emptyList() else programmes,
                        windowStart = cursor.windowStart,
                        window = window,
                        now = model.now,
                        dpPerSecond = dpPerSecond,
                        timeline = timeline,
                        selectedTime = if (row == cursor.row) cursor.time else null,
                        focused = focused,
                    )
                }
            }
        }
        // The now line, across the header and the rows.
        val now = model.now
        if (now >= cursor.windowStart && now < cursor.windowStart + window) {
            Box(
                Modifier
                    .offset(x = ChannelColumn + ((now - cursor.windowStart) * dpPerSecond).toFloat().dp)
                    .width(2.dp)
                    .fillMaxHeight()
                    .background(LumioColors.accent),
            )
        }
    }
}

@Composable
private fun TimeHeader(windowStart: Double, window: Double, now: Double, dpPerSecond: Float, format: java.text.DateFormat) {
    Row(Modifier.fillMaxWidth().height(30.dp)) {
        val day = dayPrefix(windowStart, now).trim().ifEmpty { "Today" }
        Text(day, color = LumioColors.secondaryText, fontSize = 14.sp, modifier = Modifier.width(ChannelColumn).padding(start = 24.dp, top = 4.dp))
        Box(Modifier.weight(1f).fillMaxHeight()) {
            var mark = GuideNavigation.ceilSlot(windowStart)
            while (mark < windowStart + window) {
                Text(format.format(date(mark)), color = LumioColors.secondaryText, fontSize = 14.sp,
                    modifier = Modifier.offset(x = ((mark - windowStart) * dpPerSecond).toFloat().dp + 6.dp, y = 4.dp))
                mark += GuideNavigation.SLOT
            }
        }
    }
}

@Composable
private fun GuideRow(
    channel: Channel,
    /** Null while loading. */
    programmes: List<Programme>?,
    windowStart: Double,
    window: Double,
    now: Double,
    dpPerSecond: Float,
    timeline: Dp,
    /** The highlight's time, on the highlighted row only. */
    selectedTime: Double?,
    focused: Boolean,
) {
    val windowEnd = windowStart + window
    val selectedCell = selectedTime?.let { GuideNavigation.cell(programmes.orEmpty(), it) }
    val highlight = if (focused) LumioColors.accent else LumioColors.focus
    val onHighlight = if (focused) LumioColors.onAccent else Color.White
    Row(Modifier.fillMaxWidth().height(RowHeight).padding(vertical = 2.dp)) {
        Row(
            Modifier
                .width(ChannelColumn)
                .fillMaxHeight()
                .padding(end = 4.dp)
                .background(if (selectedTime != null) LumioColors.raised else LumioColors.surface, RoundedCornerShape(4.dp))
                .padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(channel.number?.toString() ?: "", color = LumioColors.secondaryText, fontSize = 14.sp, modifier = Modifier.width(40.dp))
            RemoteImage(channel.logo, 34.dp)
            Text(channel.name, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(start = 8.dp).weight(1f))
            if (channel.favorite) Text("★", color = LumioColors.accent, fontSize = 13.sp, modifier = Modifier.padding(start = 4.dp))
        }
        Box(Modifier.width(timeline).fillMaxHeight()) {
            if (programmes != null && programmes.isEmpty()) {
                Cell("No guide information", 0.dp, timeline, LumioColors.surface, LumioColors.secondaryText)
            }
            programmes?.forEach { programme ->
                val start = maxOf(programme.start, windowStart)
                val stop = minOf(programme.stop, windowEnd)
                if (stop <= start) return@forEach
                val selected = selectedCell?.programme?.start == programme.start
                val on = programme.isOn(now)
                Cell(
                    text = (if (programme.start < windowStart) "‹ " else "") + programme.title,
                    x = ((start - windowStart) * dpPerSecond).toFloat().dp,
                    width = ((stop - start) * dpPerSecond).toFloat().dp,
                    background = when {
                        selected -> highlight
                        on -> LumioColors.focus.copy(alpha = 0.6f)
                        else -> LumioColors.surface
                    },
                    color = when {
                        selected -> onHighlight
                        programme.stop <= now -> LumioColors.secondaryText
                        else -> LumioColors.text
                    },
                )
            }
            // A highlighted gap (no programme there).
            if (selectedCell != null && selectedCell.programme == null) {
                val start = maxOf(selectedCell.start, windowStart)
                val stop = minOf(selectedCell.stop, windowEnd)
                if (stop > start) {
                    Cell(
                        text = if (programmes == null) "" else "No information",
                        x = ((start - windowStart) * dpPerSecond).toFloat().dp,
                        width = ((stop - start) * dpPerSecond).toFloat().dp,
                        background = highlight, color = onHighlight,
                    )
                }
            }
        }
    }
}

@Composable
private fun Cell(text: String, x: Dp, width: Dp, background: Color, color: Color) {
    if (width < 2.dp) return
    Box(
        Modifier
            .offset(x = x)
            .width(width - 2.dp)
            .fillMaxHeight()
            .background(background, RoundedCornerShape(4.dp))
            .padding(horizontal = 8.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        Text(text, color = color, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/**
 * Tells a press of OK from a hold. A hold is reported when OK is let go, so the release can't land
 * on whatever the hold opens.
 */
class PressTracker {
    enum class Result { None, Click, LongClick }

    private var down = false
    private var held = false

    fun ok(keyDown: Boolean, repeatCount: Int): Result {
        if (keyDown) {
            if (repeatCount == 0) {
                down = true
                held = false
            } else if (down) {
                held = true
            }
            return Result.None
        }
        if (!down) return Result.None
        down = false
        return if (held) Result.LongClick else Result.Click
    }
}
