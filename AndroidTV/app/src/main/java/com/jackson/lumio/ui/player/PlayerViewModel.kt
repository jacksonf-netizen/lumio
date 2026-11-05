package com.jackson.lumio.ui.player

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.jackson.lumio.core.CoreException
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

    init {
        viewModelScope.launch {
            LumioCore.events.filter { it.type == "player" && it.state?.player == "main" }.collect { event ->
                val previousChannel = state?.channel?.id
                state = event.state
                if (event.state?.channel?.id != previousChannel) channelChanged()
            }
        }
    }

    fun watch(channel: String, group: String) = run { LumioCore.watch(channel, group).also { showing = true } }

    /** A movie or episode; see [LumioCore.playVOD]. */
    fun playVOD(kind: String, provider: String, id: String, position: Double?, title: String, subtitle: String?) =
        run { LumioCore.playVOD(kind, provider, id, position, title, subtitle).also { showing = true } }

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
            runCatching { state = LumioCore.seek(target) }
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
        bannerJob?.cancel()
        bannerJob = viewModelScope.launch {
            delay(5000)
            bannerVisible = false
        }
    }

    private fun channelChanged() {
        nowNext = null
        showBanner()
        val epg = state?.channel?.epg ?: return
        viewModelScope.launch { nowNext = runCatching { LumioCore.nowNext(listOf(epg))[epg] }.getOrNull() }
    }

    private fun run(work: suspend () -> PlayerState) {
        viewModelScope.launch {
            try {
                val previousChannel = state?.channel?.id
                state = work()
                error = null
                if (state?.channel?.id != previousChannel) channelChanged()
            } catch (failure: CoreException) {
                error = failure.message
            }
        }
    }
}
