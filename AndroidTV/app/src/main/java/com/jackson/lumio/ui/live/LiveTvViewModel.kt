package com.jackson.lumio.ui.live

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.jackson.lumio.core.Channel
import com.jackson.lumio.core.ChannelGroup
import com.jackson.lumio.core.CoreException
import com.jackson.lumio.core.EPGRef
import com.jackson.lumio.core.LumioCore
import com.jackson.lumio.core.NowNext
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch

data class LiveTvState(
    val groups: List<ChannelGroup> = emptyList(),
    val selectedGroup: String = "all",
    val channels: List<Channel> = emptyList(),
    val nowNext: Map<EPGRef, NowNext> = emptyMap(),
    /** The time (seconds since 1970) the rows' progress bars are drawn for; moves on every minute. */
    val clock: Double = System.currentTimeMillis() / 1000.0,
    val loading: Boolean = true,
    val message: String? = null,
)

/** Live TV: the merged groups and channels from the shared core, with now/next for rows on screen. */
@OptIn(FlowPreview::class)
class LiveTvViewModel : ViewModel() {
    var state by mutableStateOf(LiveTvState())
        private set

    private var channelJob: Job? = null
    private val wanted = mutableSetOf<EPGRef>()
    /**
     * The rows shown lately (most recent last), asked again when the guide changes or a programme
     * ends. Rows that had no guide yet are here too, so they fill in once it arrives.
     */
    private val shown = LinkedHashSet<EPGRef>()
    private var nowNextJob: Job? = null

    init {
        reloadGroups()
        viewModelScope.launch {
            LumioCore.events.filter { it.type == "live" }.debounce(400).collect { reloadGroups() }
        }
        viewModelScope.launch {
            LumioCore.events.filter { it.type == "guide" }.debounce(1000).collect { refreshNowNext() }
        }
        // What's on moves along while the list stays open.
        viewModelScope.launch {
            while (true) {
                delay(60_000)
                val now = System.currentTimeMillis() / 1000.0
                state = state.copy(clock = now)
                val moved = state.nowNext.values.any { entry ->
                    entry.now?.let { it.stop <= now } ?: (entry.next?.let { it.start <= now } ?: false)
                }
                if (moved) refreshNowNext()
            }
        }
    }

    fun select(group: String) {
        if (group == state.selectedGroup) return
        state = state.copy(selectedGroup = group)
        reloadChannels()
    }

    /** A row came on screen; its now/next loads with the others shown at the same time. */
    fun wantNowNext(ref: EPGRef) {
        shown.remove(ref)
        shown.add(ref)
        if (shown.size > MAX_SHOWN) shown.remove(shown.first())
        if (state.nowNext.containsKey(ref) || !wanted.add(ref)) return
        loadNowNext()
    }

    /** Asks again for every row shown lately, dropping what's no longer on. */
    private fun refreshNowNext() {
        if (shown.isEmpty()) return
        wanted.addAll(shown)
        replaceNext = true
        loadNowNext()
    }

    /** The next load replaces what's known for the rows it asked about, rather than only adding. */
    private var replaceNext = false

    private fun loadNowNext() {
        if (nowNextJob?.isActive == true) return
        nowNextJob = viewModelScope.launch {
            delay(150)
            val refs = wanted.toList()
            wanted.clear()
            val replace = replaceNext
            replaceNext = false
            val result = runCatching { LumioCore.nowNext(refs) }
            val found = result.getOrDefault(emptyMap())
            // A row whose guide has run out loses its line; a failed request leaves things as they are.
            val kept = if (replace && result.isSuccess) state.nowNext - refs.toSet() else state.nowNext
            state = state.copy(nowNext = kept + found)
            if (wanted.isNotEmpty()) loadNowNext()
        }
    }

    /** Adds to Favorites or takes out; the list updates from the core's change event. */
    fun toggleFavorite(channel: Channel) {
        viewModelScope.launch {
            try {
                LumioCore.toggleFavorite(channel.id)
            } catch (error: CoreException) {
                state = state.copy(message = error.message)
            }
        }
    }

    private companion object {
        /** Enough for the rows on screen and those just scrolled past. */
        const val MAX_SHOWN = 200
    }

    private fun reloadGroups() {
        viewModelScope.launch {
            try {
                val groups = LumioCore.groups()
                val selected = if (groups.any { it.id == state.selectedGroup }) state.selectedGroup else "all"
                state = state.copy(groups = groups, selectedGroup = selected, message = null)
                reloadChannels()
            } catch (error: CoreException) {
                state = state.copy(loading = false, message = error.message)
            }
        }
    }

    private fun reloadChannels() {
        channelJob?.cancel()
        val group = state.selectedGroup
        channelJob = viewModelScope.launch {
            state = state.copy(loading = state.channels.isEmpty())
            try {
                val channels = LumioCore.channels(group)
                if (group == state.selectedGroup) state = state.copy(channels = channels, loading = false)
            } catch (error: CoreException) {
                state = state.copy(loading = false, message = error.message)
            }
        }
    }
}
