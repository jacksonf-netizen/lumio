package com.jackson.lumio.ui.player

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.jackson.lumio.core.Channel
import com.jackson.lumio.core.CoreException
import com.jackson.lumio.core.EPGRef
import com.jackson.lumio.core.LumioCore
import com.jackson.lumio.core.NowNext
import com.jackson.lumio.core.PlayerState
import com.jackson.lumio.core.Track
import com.jackson.lumio.player.PlayerEngines
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch

/**
 * The full-screen player. Every decision (what to play next, retries, fallbacks, zapping) is the
 * core's; this keeps what the screen shows: the state, the info banner and typed digits.
 */
class PlayerViewModel : ViewModel() {
    var state by mutableStateOf<PlayerState?>(null)
        private set
    var showing by mutableStateOf(false)
        private set
    var bannerVisible by mutableStateOf(false)
        private set
    var nowNext by mutableStateOf<NowNext?>(null)
        private set
    /** Digits typed on the remote, before they pick a channel. */
    var digits by mutableStateOf("")
        private set
    var error by mutableStateOf<String?>(null)
        private set
    /** The audio and subtitle tracks, while the tracks panel is open. */
    var tracks by mutableStateOf<List<Track>?>(null)
        private set

    private var bannerJob: Job? = null
    private var digitsJob: Job? = null

    /**
     * How many player events have arrived. A request's reply holds the state from when the core
     * answered, and an event sent just after it (the engine reporting "paused", say) can reach the
     * screen first. The reply is then the older of the two, so [showReply] drops it.
     */
    private var eventsSeen = 0

    /** Runs a request and shows the state it returns, unless an event brought a newer one meanwhile. */
    private suspend fun showReply(work: suspend () -> PlayerState) {
        val before = eventsSeen
        val reply = work()
        if (eventsSeen == before) state = reply
    }

    init {
        viewModelScope.launch {
            LumioCore.events.filter { it.type == "player" && it.state?.player == "main" }.collect { event ->
                eventsSeen++
                val previousChannel = state?.channel?.id
                state = event.state
                if (event.state?.channel?.id != previousChannel) channelChanged()
            }
        }
    }

    /** The Live TV group the channel was watched from (for multiview's "watch full screen"). */
    var group: String? = null
        private set

    /** What is being opened ("Opening <name>…" on screen) while the core's answer is awaited, else null. */
    var opening by mutableStateOf<String?>(null)
        private set
    /** Why the last channel or movie couldn't be opened, shown with a Close button. */
    var openError by mutableStateOf<String?>(null)
        private set
    /** Counts opens, so a late answer to an older one (or to one closed with Back) is ignored. */
    private var openCount = 0

    /** [name] is the channel's name, if the caller has it, for the "Opening…" line. */
    fun watch(channel: String, group: String, name: String? = null) {
        this.group = group
        open(name?.let { "Opening $it…" } ?: "Opening…") { LumioCore.watch(channel, group) }
    }

    /** Hides the player without stopping it: multiview stops it before its tiles start. */
    fun dismiss() {
        tracks = null
        openCount++
        opening = null
        showing = false
    }

    /** A movie or episode; see [LumioCore.playVOD]. */
    fun playVOD(kind: String, provider: String, id: String, position: Double?, title: String, subtitle: String?) =
        open("Opening $title…") { LumioCore.playVOD(kind, provider, id, position, title, subtitle) }

    /**
     * Shows the player at once, with [label], then waits for the core (which can take seconds on a
     * big provider). If it fails, the screen says why instead of staying black.
     */
    private fun open(label: String, work: suspend () -> PlayerState) {
        val token = ++openCount
        error = null
        openError = null
        opening = label
        if (!showing) {
            // Nothing from the last time (a stale "failed", the old channel) shows meanwhile.
            state = null
            nowNext = null
        }
        showing = true
        viewModelScope.launch {
            try {
                val previousChannel = state?.channel?.id
                val before = eventsSeen
                val reply = work()
                if (token != openCount) return@launch
                if (eventsSeen == before) state = reply
                if (state?.channel?.id != previousChannel) channelChanged()
            } catch (failure: CoreException) {
                if (token == openCount) openError = failure.message ?: "Something went wrong."
            } finally {
                if (token == openCount) opening = null
            }
        }
    }

    /** Where a skip is heading while the remote is still being pressed (seconds), or null. */
    var seekTarget by mutableStateOf<Double?>(null)
        private set
    private var seekJob: Job? = null

    /** Pauses or resumes a movie or episode, showing the controls. */
    fun togglePause() {
        showBanner()
        run { if (state?.phase == "paused") LumioCore.resume() else LumioCore.pause() }
    }

    /**
     * Skips by [seconds]. Presses close together add up and the skip happens 0.6 s after the last,
     * so holding the remote doesn't send a seek per press.
     */
    fun skip(seconds: Double) {
        val (position, duration) = PlayerEngines.engine("main").timeline ?: return
        val from = seekTarget ?: position
        seekTarget = (from + seconds).coerceIn(0.0, duration?.let { maxOf(0.0, it - 5) } ?: Double.MAX_VALUE)
        showBanner()
        seekJob?.cancel()
        seekJob = viewModelScope.launch {
            delay(600)
            val target = seekTarget ?: return@launch
            runCatching { showReply { LumioCore.seek(target) } }
            delay(400) // the player reports the new position
            seekTarget = null
        }
    }

    fun zap(by: Int) = run { LumioCore.zap(by) }

    fun previous() = run { LumioCore.previousChannel() }

    fun retry() = run { LumioCore.retry() }

    fun openTracks() {
        viewModelScope.launch { tracks = runCatching { LumioCore.tracks() }.getOrDefault(emptyList()) }
    }

    fun closeTracks() {
        tracks = null
    }

    fun selectTrack(kind: String, id: Int?) {
        viewModelScope.launch {
            runCatching { LumioCore.selectTrack(kind, id) }
            delay(300)
            tracks = runCatching { LumioCore.tracks() }.getOrDefault(tracks.orEmpty())
        }
    }

    fun close() {
        tracks = null
        openCount++
        opening = null
        openError = null
        seekJob?.cancel()
        seekTarget = null
        showing = false
        viewModelScope.launch { runCatching { LumioCore.stopPlayer() } }
    }

    /** A digit from the remote: the number is used 1.5 s after the last digit. */
    fun digit(value: Int) {
        if (digits.length >= 5) return
        digits += value
        digitsJob?.cancel()
        digitsJob = viewModelScope.launch {
            delay(1500)
            val number = digits.toIntOrNull()
            digits = ""
            if (number != null) run { LumioCore.channelNumber(number) }
        }
    }

    fun showBanner() {
        bannerVisible = true
        loadNowNext()
        bannerJob?.cancel()
        bannerJob = viewModelScope.launch {
            delay(5000)
            bannerVisible = false
        }
    }

    // MARK: Channel list (OK on live TV)

    /** The channels of the group playing, with what's on, over the video (OK on live TV). */
    var channelList by mutableStateOf<ChannelList?>(null)
        private set

    /** [loading]: the panel is open but the channels haven't been read yet. */
    data class ChannelList(val channels: List<Channel>, val nowNext: Map<EPGRef, NowNext>, val start: Int, val loading: Boolean = false)

    fun openChannels() {
        val current = state?.channel?.id
        // The panel opens at once with a "Loading channels…" row; a big group takes a while.
        val waiting = ChannelList(emptyList(), emptyMap(), 0, loading = true)
        channelList = waiting
        viewModelScope.launch {
            val channels = runCatching { LumioCore.channels(group ?: "all") }.getOrNull().orEmpty()
            // Closed with Back meanwhile: leave it closed.
            if (channelList !== waiting) return@launch
            if (channels.isEmpty()) {
                channelList = null
                showBanner()
                return@launch
            }
            val start = channels.indexOfFirst { it.id == current }.coerceAtLeast(0)
            channelList = ChannelList(channels, emptyMap(), start)
            loadNowNextAround(start)
        }
    }

    /** What's on for the rows near [index], for those not read yet (a long group is read as it scrolls). */
    fun loadNowNextAround(index: Int) {
        val list = channelList ?: return
        val refs = list.channels.subList(maxOf(0, index - 20), minOf(list.channels.size, index + 40))
            .mapNotNull { it.epg }.filter { it !in list.nowNext }.distinct()
        if (refs.isEmpty()) return
        viewModelScope.launch {
            val found = runCatching { LumioCore.nowNext(refs) }.getOrNull() ?: return@launch
            val now = channelList ?: return@launch
            // Rows with nothing on are remembered too, so they aren't asked for again.
            val empty = refs.associateWith { NowNext(it, null, null) }
            channelList = now.copy(nowNext = now.nowNext + empty + found)
        }
    }

    fun closeChannels() {
        channelList = null
    }

    /** Plays [channel] from the list (the one playing just closes the list). */
    fun pickChannel(channel: Channel) {
        channelList = null
        if (channel.id != state?.channel?.id) watch(channel.id, group ?: "all")
    }

    private fun channelChanged() {
        nowNext = null
        showBanner()
    }

    /** What's on, asked each time the banner shows so it's right however long the channel has played. */
    private fun loadNowNext() {
        val epg = state?.channel?.epg ?: return
        viewModelScope.launch {
            val found = runCatching { LumioCore.nowNext(listOf(epg))[epg] }.getOrNull()
            if (state?.channel?.epg == epg) nowNext = found
        }
    }

    private fun run(work: suspend () -> PlayerState) {
        viewModelScope.launch {
            try {
                val previousChannel = state?.channel?.id
                showReply(work)
                error = null
                if (state?.channel?.id != previousChannel) channelChanged()
            } catch (failure: CoreException) {
                error = failure.message
            }
        }
    }
}
