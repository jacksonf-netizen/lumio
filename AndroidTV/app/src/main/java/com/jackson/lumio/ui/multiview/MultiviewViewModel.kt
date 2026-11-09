package com.jackson.lumio.ui.multiview

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.jackson.lumio.core.CoreException
import com.jackson.lumio.core.LumioCore
import com.jackson.lumio.core.MultiviewState
import com.jackson.lumio.player.DecoderLimits
import com.jackson.lumio.player.PlayerEngines
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch

/**
 * Multiview: 2 to 4 live channels at once. The tiles, which provider each plays from, and the
 * "no free connection" warning are the shared core's (MultiviewSession, as on the Mac); this keeps
 * what the screen shows and how many tiles this TV's decoder allows ([limits]).
 */
class MultiviewViewModel(application: Application) : AndroidViewModel(application) {
    val limits = DecoderLimits.of(application)
    /** Multiview is offered at all: the decoder manages at least 2 videos. */
    val available get() = limits.maxTiles >= 2
    /** The layouts this TV can play. */
    val layouts get() = (2..limits.maxTiles).toList()

    var state by mutableStateOf<MultiviewState?>(null)
        private set
    var showing by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    private var eventsSeen = 0

    init {
        viewModelScope.launch {
            LumioCore.events.filter { it.type == "multiview" }.collect { event ->
                event.multiview?.let {
                    eventsSeen++
                    state = it
                }
            }
        }
    }

    /**
     * Opens multiview with [channel] from [group] in the first empty tile (the full-screen player
     * stops first). The tiles from last time come back; the layout is the last one used, if this
     * TV can still play it.
     */
    fun start(channel: String?, group: String?) {
        val layout = (state?.layout ?: 2).coerceIn(2, limits.maxTiles)
        showing = true
        run { LumioCore.startMultiview(layout, channel, group) }
    }

    fun setLayout(layout: Int) = run { LumioCore.multiviewLayout(layout.coerceIn(2, limits.maxTiles)) }

    fun setChannel(tile: Int, channel: String, group: String) = run { LumioCore.setTileChannel(tile, channel, group) }

    fun clearTile(tile: Int) = run { LumioCore.clearTile(tile) }

    /** The highlighted tile is the one heard. */
    fun focusAudio(tile: Int) {
        if (state?.audioTile != tile) run { LumioCore.focusTileAudio(tile) }
    }

    fun retry(tile: Int) = run { LumioCore.retryTile(tile) }

    /** [provider] null: automatic. */
    fun pin(tile: Int, provider: String?) = run { LumioCore.pinTileProvider(tile, provider) }

    /** Closes multiview; [then] runs once every tile's stream is closed (to play full screen). */
    fun stop(then: (() -> Unit)? = null) {
        showing = false
        viewModelScope.launch {
            runCatching { state = LumioCore.stopMultiview() }
            PlayerEngines.releaseTiles()
            then?.invoke()
        }
    }

    private fun run(work: suspend () -> MultiviewState) {
        viewModelScope.launch {
            try {
                // An event that arrived while the request was out is newer than its reply (see
                // PlayerViewModel.showReply).
                val before = eventsSeen
                val reply = work()
                if (eventsSeen == before) state = reply
                error = null
            } catch (failure: CoreException) {
                error = failure.message
            }
        }
    }
}
