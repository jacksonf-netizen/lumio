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

    fun zap(by: Int) = run { LumioCore.zap(by) }

    fun previous() = run { LumioCore.previousChannel() }

    fun retry() = run { LumioCore.retry() }

    fun close() {
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
