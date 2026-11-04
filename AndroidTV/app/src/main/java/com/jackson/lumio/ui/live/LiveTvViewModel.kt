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
    private var nowNextJob: Job? = null

    init {
        reloadGroups()
        viewModelScope.launch {
            LumioCore.events.filter { it.type == "live" }.debounce(400).collect { reloadGroups() }
        }
        viewModelScope.launch {
            LumioCore.events.filter { it.type == "guide" }.debounce(1000).collect {
                wanted.addAll(state.nowNext.keys)
                state = state.copy(nowNext = emptyMap())
                loadNowNext()
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
        if (state.nowNext.containsKey(ref) || !wanted.add(ref)) return
        loadNowNext()
    }

    private fun loadNowNext() {
        if (nowNextJob?.isActive == true) return
        nowNextJob = viewModelScope.launch {
            delay(150)
            val refs = wanted.toList()
            wanted.clear()
            val found = runCatching { LumioCore.nowNext(refs) }.getOrDefault(emptyMap())
            state = state.copy(nowNext = state.nowNext + found)
            if (wanted.isNotEmpty()) loadNowNext()
        }
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
