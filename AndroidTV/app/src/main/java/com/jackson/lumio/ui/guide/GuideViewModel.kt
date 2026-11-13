package com.jackson.lumio.ui.guide

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.jackson.lumio.core.Channel
import com.jackson.lumio.core.ChannelGroup
import com.jackson.lumio.core.CoreException
import com.jackson.lumio.core.EPGRef
import com.jackson.lumio.core.LumioCore
import com.jackson.lumio.core.Programme
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch
import kotlin.math.floor

/** Which channels a guide page shows: any group (with a picker), or a fixed list. */
enum class GuideScope(val group: String?) {
    All(null),
    Favorites("favorites"),
    Recents("recents"),
}

/**
 * The guide grid: the channels of one group and their programmes, loaded in four-hour blocks for
 * the rows near the screen only, so a big guide never sits in memory (the onn HD stick has 1.5 GB
 * for everything). The highlight's movement rules are in [GuideNavigation].
 */
@OptIn(FlowPreview::class)
class GuideViewModel(val scope: GuideScope, context: Context) : ViewModel() {
    private val preferences = context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    var groups by mutableStateOf<List<ChannelGroup>>(emptyList())
        private set
    var groupID by mutableStateOf(scope.group ?: "all")
        private set
    var channels by mutableStateOf<List<Channel>>(emptyList())
        private set
    /** True once the first channel list has arrived (so an empty list means none, not loading). */
    var loaded by mutableStateOf(false)
        private set
    var message by mutableStateOf<String?>(null)
        private set
    var cursor by mutableStateOf(GuideCursor(0, nowSeconds(), GuideNavigation.floorSlot(nowSeconds())))
        private set
    /** Seconds across the grid; set by the screen from its width. */
    var window by mutableDoubleStateOf(5400.0)
        private set
    /** The clock, moved on every 30 seconds for the now line. */
    var now by mutableDoubleStateOf(nowSeconds())
        private set
    /** Bumped whenever programmes arrive, so rows read them again. */
    var version by mutableIntStateOf(0)
        private set
    /** Digits typed on the remote, before they pick a channel. */
    var digits by mutableStateOf("")
        private set

    /** The guide keeps one day of the past and a week ahead (as the core's import does). */
    val minTime get() = GuideNavigation.floorSlot(now - GuideNavigation.DAY)
    val maxTime get() = now + 7 * GuideNavigation.DAY

    private val blocks = object : LinkedHashMap<Pair<EPGRef, Long>, List<Programme>>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Pair<EPGRef, Long>, List<Programme>>): Boolean =
            size > MAX_BLOCKS
    }
    private val requested = mutableSetOf<Pair<EPGRef, Long>>()
    private val pending = mutableSetOf<Pair<EPGRef, Long>>()
    private var flushJob: Job? = null
    private var channelJob: Job? = null
    private var digitsJob: Job? = null
    private var visibleRows = 0..0
    /** The first group has been picked (the one kept from last time, or the fallback). */
    private var groupChecked = false
    /** Keeps the highlight on the same channel when the list changes. */
    private var cursorChannel: String? = null

    init {
        reload()
        viewModelScope.launch {
            LumioCore.events.filter { it.type == "live" }.debounce(400).collect { reload() }
        }
        viewModelScope.launch {
            // Favorites or Recently Watched changed: only those two lists need reading again.
            LumioCore.events.filter { it.type == "library" }.debounce(400).collect {
                if (groupID == "favorites" || groupID == "recents") reloadChannels()
            }
        }
        viewModelScope.launch {
            LumioCore.events.filter { it.type == "guide" }.debounce(1000).collect { forgetProgrammes() }
        }
        viewModelScope.launch {
            while (true) {
                delay(30_000)
                now = nowSeconds()
            }
        }
    }

    // MARK: Channels

    fun selectGroup(id: String) {
        if (scope != GuideScope.All || id == groupID) return
        groupID = id
        preferences.edit().putString(KEY_GROUP, id).apply()
        cursorChannel = null
        cursor = cursor.copy(row = 0)
        reloadChannels()
    }

    private fun reload() {
        viewModelScope.launch {
            try {
                if (scope == GuideScope.All) {
                    val all = LumioCore.groups()
                    // All Channels goes last: with a huge provider it's the slowest group to open.
                    groups = all.filter { it.id != "all" } + all.filter { it.id == "all" }
                    if (!groupChecked) {
                        // First time: the group chosen last time, if it's still there.
                        groupChecked = true
                        val saved = preferences.getString(KEY_GROUP, null)
                        groupID = saved?.takeIf { id -> groups.any { it.id == id } } ?: fallbackGroup()
                    } else if (groups.none { it.id == groupID }) {
                        groupID = fallbackGroup()
                    }
                }
                reloadChannels()
            } catch (error: CoreException) {
                message = error.message
                loaded = true
            }
        }
    }

    /** Favorites if it has channels, else the first ordinary category, else All Channels. */
    private suspend fun fallbackGroup(): String {
        val favorites = runCatching { LumioCore.channels("favorites") }.getOrNull().orEmpty()
        if (favorites.isNotEmpty()) return "favorites"
        return groups.firstOrNull { it.kind == "category" }?.id ?: "all"
    }

    private fun reloadChannels() {
        channelJob?.cancel()
        val group = groupID
        channelJob = viewModelScope.launch {
            try {
                val list = LumioCore.channels(group)
                if (group != groupID) return@launch
                channels = list
                loaded = true
                message = null
                val row = cursorChannel?.let { id -> list.indexOfFirst { it.id == id } }?.takeIf { it >= 0 }
                cursor = cursor.copy(row = (row ?: cursor.row).coerceIn(0, maxOf(0, list.size - 1)))
                cursorChannel = list.getOrNull(cursor.row)?.id
                requestVisible()
            } catch (error: CoreException) {
                message = error.message
                loaded = true
            }
        }
    }

    val selectedChannel: Channel? get() = channels.getOrNull(cursor.row)

    /** The highlighted cell, or null while its row's guide is still loading. */
    val selectedCell: GuideCell?
        get() {
            val channel = selectedChannel ?: return null
            val programmes = channel.epg?.let { programmes(it, cursor.windowStart, cursor.windowStart + window) }
                ?: if (channel.epg == null) emptyList() else return null
            return GuideNavigation.cell(programmes, cursor.time)
        }

    // MARK: Programmes

    /**
     * The programmes of [ref] between [start] and [end], or null if they haven't loaded yet. Reads
     * [version], so a row shows its programmes as they arrive.
     */
    fun programmes(ref: EPGRef, start: Double, end: Double): List<Programme>? {
        version
        if (blockRange(start, end).any { (ref to it) !in blocks }) return null
        return loadedProgrammes(ref, start, end)
    }

    /** What has loaded of [ref] between [start] and [end]. A programme across two blocks is in both. */
    private fun loadedProgrammes(ref: EPGRef, start: Double, end: Double): List<Programme> {
        val result = mutableListOf<Programme>()
        for (block in blockRange(start, end)) {
            for (programme in blocks[ref to block].orEmpty()) {
                if (programme.stop > start && programme.start < end && result.none { it.start == programme.start }) result += programme
            }
        }
        return result.sortedBy { it.start }
    }

    /** The screen reports which rows it shows; programmes load for those and a few either side. */
    fun showingRows(rows: IntRange) {
        if (rows == visibleRows) return
        visibleRows = rows
        requestVisible()
    }

    fun useWindow(seconds: Double) {
        if (seconds == window) return
        window = seconds
        requestVisible()
    }

    private fun requestVisible() {
        val first = maxOf(0, visibleRows.first - ROW_MARGIN)
        val last = minOf(channels.size - 1, maxOf(visibleRows.last, cursor.row) + ROW_MARGIN)
        if (last < first) return
        val range = blockRange(cursor.windowStart - 3600, cursor.windowStart + window + 3600)
        for (row in first..last) {
            val ref = channels[row].epg ?: continue
            for (block in range) {
                val key = ref to block
                if (key !in blocks && requested.add(key)) pending += key
            }
        }
        if (pending.isEmpty() || flushJob?.isActive == true) return
        flushJob = viewModelScope.launch {
            delay(60)
            while (pending.isNotEmpty()) {
                val batch = pending.toList()
                pending.clear()
                // One request per block, covering every row that needs it.
                for ((block, keys) in batch.groupBy { it.second }) {
                    val start = block * BLOCK
                    val refs = keys.map { it.first }
                    val found = runCatching { LumioCore.guide(refs, start, start + BLOCK) }.getOrNull()
                    for (ref in refs) {
                        requested -= ref to block
                        if (found != null) blocks[ref to block] = found[ref].orEmpty()
                    }
                }
                version++
            }
        }
    }

    /** After a guide import: everything reloads. */
    private fun forgetProgrammes() {
        blocks.clear()
        requested.clear()
        version++
        requestVisible()
    }

    private fun blockRange(start: Double, end: Double): LongRange =
        floor(start / BLOCK).toLong()..floor((end - 1) / BLOCK).toLong()

    // MARK: Moving

    private fun rowProgrammes(row: Int): List<Programme> {
        val ref = channels.getOrNull(row)?.epg ?: return emptyList()
        return loadedProgrammes(ref, cursor.windowStart - BLOCK, cursor.windowStart + window + BLOCK)
    }

    fun right() = update(GuideNavigation.right(cursor, rowProgrammes(cursor.row), window, maxTime))

    fun left() = update(GuideNavigation.left(cursor, rowProgrammes(cursor.row), window, minTime))

    fun move(by: Int) = update(GuideNavigation.move(cursor, by, channels.size))

    fun day(by: Int) = update(GuideNavigation.day(cursor, by, minTime, maxTime))

    fun jumpToNow() {
        now = nowSeconds()
        update(GuideNavigation.now(cursor, now))
    }

    /** True when the grid starts at the current half hour (Back then leaves the guide). */
    val atNow: Boolean get() = cursor.windowStart == GuideNavigation.floorSlot(now)

    fun moveTo(channelID: String) {
        val row = channels.indexOfFirst { it.id == channelID }
        if (row >= 0) update(cursor.copy(row = row))
    }

    /** A digit from the remote: the guide jumps to that channel number 1.2 s after the last digit. */
    fun digit(value: Int) {
        if (digits.length >= 5) return
        digits += value
        digitsJob?.cancel()
        digitsJob = viewModelScope.launch {
            delay(1200)
            val number = digits.toIntOrNull()
            digits = ""
            if (number != null) GuideNavigation.rowForNumber(channels.map { it.number }, number)?.let { update(cursor.copy(row = it)) }
        }
    }

    private fun update(next: GuideCursor?) {
        if (next == null || next == cursor) return
        cursor = next
        cursorChannel = channels.getOrNull(next.row)?.id
        requestVisible()
    }

    // MARK: Favorites and Recents

    fun toggleFavorite(channel: Channel) = library {
        LumioCore.toggleFavorite(channel.id)
        // Other groups don't re-read on a library event, so the star changes here.
        channels = channels.map { if (it.id == channel.id) it.copy(favorite = !it.favorite) else it }
    }

    /** In Favorites: moves the channel to [index] (the highlight goes with it). */
    fun moveFavorite(channel: Channel, index: Int) = library {
        cursorChannel = channel.id
        LumioCore.moveFavorite(channel.id, index)
    }

    fun removeRecent(channel: Channel) = library { LumioCore.removeRecent(channel.id) }

    fun clearRecents() = library { LumioCore.clearRecents() }

    private fun library(work: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                work()
            } catch (error: CoreException) {
                message = error.message
            }
        }
    }

    companion object {
        private const val PREFERENCES = "guide"
        private const val KEY_GROUP = "group"
        const val BLOCK = 4 * 3600.0
        /** Programme blocks kept (each a few kilobytes); the least recently shown go first. */
        const val MAX_BLOCKS = 600
        const val ROW_MARGIN = 6

        fun nowSeconds(): Double = System.currentTimeMillis() / 1000.0
    }
}
