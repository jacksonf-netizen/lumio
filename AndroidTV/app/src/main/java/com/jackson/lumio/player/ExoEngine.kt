package com.jackson.lumio.player

import android.app.ActivityManager
import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.jackson.lumio.core.LumioCore
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONArray
import org.json.JSONObject

/**
 * One player for the core's PlaybackController (the Android counterpart of the Mac's mpv and
 * AVPlayer engines). The core decides what to play, when to retry and what to fall back to; this
 * only does what it's told (load, stop, …) and reports what happens, in the core's terms, with
 * the load id the core gave so it can ignore a stream it has already replaced. All on the UI
 * thread, where both the core's main actor and ExoPlayer run.
 */
@OptIn(UnstableApi::class)
class ExoEngine(private val context: Context, private val id: String) {
    private var player: ExoPlayer? = null
    private var playerBuffer: Pair<Double, Int>? = null
    private var loadID = 0
    private val bytesReceived = AtomicLong()
    private var droppedFrames = 0
    private var decoderName: String? = null
    private var volume = 1f
    private var muted = false
    private val lowRam = context.getSystemService(ActivityManager::class.java).isLowRamDevice

    /** Listeners of the screen showing this player (PlayerView needs the ExoPlayer itself). */
    var onPlayerChanged: ((ExoPlayer?) -> Unit)? = null
        set(value) {
            field = value
            value?.invoke(player)
        }

    fun handle(command: JSONObject): Any? = when (command.getString("command")) {
        "load" -> load(command).let { null }
        "play" -> player?.play().let { null }
        "pause" -> player?.pause().let { null }
        "stop" -> stop().let { null }
        "seek" -> player?.seekTo((command.getDouble("position") * 1000).toLong()).let { null }
        "volume" -> {
            volume = command.getDouble("volume").toFloat()
            muted = command.getBoolean("muted")
            player?.volume = if (muted) 0f else volume
            null
        }
        "tracks" -> tracks()
        "select" -> select(command.getString("kind"), if (command.has("id")) command.getInt("id") else null).let { null }
        "metrics" -> metrics()
        "release" -> release().let { null }
        else -> null
    }

    // MARK: Commands

    private fun load(command: JSONObject) {
        loadID = command.getInt("loadID")
        val readAhead = command.getDouble("readAheadSeconds")
        // Low-RAM devices (the onn HD stick) buffer at most 24 MB, whatever the preset.
        val maxBytes = command.getInt("maxBytes").let { if (lowRam) minOf(it, 24 shl 20) else it }
        val timeoutMs = (command.getDouble("timeoutSeconds") * 1000).toInt()
        val player = player(readAhead, maxBytes)
        val http = DefaultHttpDataSource.Factory()
            .setUserAgent(command.getString("userAgent"))
            .setConnectTimeoutMs(timeoutMs)
            .setReadTimeoutMs(timeoutMs)
            .setAllowCrossProtocolRedirects(true)
            .setTransferListener(byteCounter)
        val source = DefaultMediaSourceFactory(DefaultDataSource.Factory(context, http))
            .createMediaSource(MediaItem.fromUri(command.getString("url")))
        droppedFrames = 0
        player.setMediaSource(source)
        if (command.has("startPosition")) player.seekTo((command.getDouble("startPosition") * 1000).toLong())
        player.prepare()
        player.playWhenReady = true
    }

    private fun stop() {
        player?.stop()
        player?.clearMediaItems()
    }

    private fun release() {
        player?.release()
        player = null
        onPlayerChanged?.invoke(null)
    }

    private fun tracks(): JSONArray {
        val list = JSONArray()
        val groups = player?.currentTracks?.groups ?: return list
        groups.forEachIndexed { groupIndex, group ->
            val kind = when (group.type) {
                C.TRACK_TYPE_AUDIO -> "audio"
                C.TRACK_TYPE_TEXT -> "subtitle"
                else -> return@forEachIndexed
            }
            for (trackIndex in 0 until group.length) {
                val format = group.getTrackFormat(trackIndex)
                list.put(JSONObject()
                    .put("id", groupIndex * 100 + trackIndex)
                    .put("kind", kind)
                    .putOpt("title", format.label)
                    .putOpt("language", format.language)
                    .putOpt("codec", format.sampleMimeType?.substringAfter('/'))
                    .put("selected", group.isTrackSelected(trackIndex)))
            }
        }
        return list
    }

    private fun select(kind: String, trackID: Int?) {
        val player = player ?: return
        val type = if (kind == "audio") C.TRACK_TYPE_AUDIO else C.TRACK_TYPE_TEXT
        val builder = player.trackSelectionParameters.buildUpon().clearOverridesOfType(type)
        if (trackID == null) {
            builder.setTrackTypeDisabled(type, true)
        } else {
            val group = player.currentTracks.groups.getOrNull(trackID / 100) ?: return
            builder.setTrackTypeDisabled(type, false).setOverrideForType(TrackSelectionOverride(group.mediaTrackGroup, trackID % 100))
        }
        player.trackSelectionParameters = builder.build()
    }

    private fun metrics(): JSONObject {
        val player = player ?: return JSONObject()
        val video = player.videoFormat
        val audio = player.audioFormat
        return JSONObject()
            .put("position", player.currentPosition / 1000.0)
            .putOpt("duration", player.duration.takeIf { it != C.TIME_UNSET }?.let { it / 1000.0 })
            .put("bufferSeconds", (player.bufferedPosition - player.currentPosition).coerceAtLeast(0) / 1000.0)
            .put("bytesReceived", bytesReceived.get())
            .putOpt("videoCodec", video?.sampleMimeType?.substringAfter('/'))
            .putOpt("audioCodec", audio?.sampleMimeType?.substringAfter('/'))
            .putOpt("width", video?.width?.takeIf { it > 0 })
            .putOpt("height", video?.height?.takeIf { it > 0 })
            .putOpt("fps", video?.frameRate?.takeIf { it > 0 }?.toDouble())
            .putOpt("bitrateKbps", video?.bitrate?.takeIf { it > 0 }?.let { it / 1000.0 })
            .put("droppedFrames", droppedFrames)
            .putOpt("decoder", decoderName)
    }

    // MARK: The player

    /** The ExoPlayer, made again when the buffer settings change (they're fixed per player). */
    private fun player(readAheadSeconds: Double, maxBytes: Int): ExoPlayer {
        val wanted = readAheadSeconds to maxBytes
        player?.let { if (playerBuffer == wanted) return it else it.release() }
        val readAheadMs = (readAheadSeconds * 1000).toInt()
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(maxOf(readAheadMs, 1500), maxOf(readAheadMs * 2, 15_000), 1000, 2000)
            .setTargetBufferBytes(maxBytes)
            .setPrioritizeTimeOverSizeThresholds(false)
            .build()
        val created = ExoPlayer.Builder(context).setLoadControl(loadControl).build()
        created.volume = if (muted) 0f else volume
        created.addListener(listener)
        created.addAnalyticsListener(analytics)
        player = created
        playerBuffer = wanted
        onPlayerChanged?.invoke(created)
        return created
    }

    private val byteCounter = object : TransferListener {
        override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
        override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
        override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) {
            if (isNetwork) bytesReceived.addAndGet(bytesTransferred.toLong())
        }
        override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
    }

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(state: Int) {
            when (state) {
                Player.STATE_BUFFERING -> send("buffering", "value" to true)
                Player.STATE_READY -> if (player?.playWhenReady == true) send("playing") else send("paused")
                Player.STATE_ENDED -> send("ended")
            }
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            if (player?.playbackState == Player.STATE_READY) send(if (playWhenReady) "playing" else "paused")
        }

        override fun onTracksChanged(tracks: Tracks) = send("tracks")

        override fun onPlayerError(error: PlaybackException) {
            val (kind, status) = classify(error)
            send("failed", "kind" to kind, "status" to status, "detail" to error.errorCodeName)
        }
    }

    private val analytics = object : AnalyticsListener {
        override fun onDroppedVideoFrames(eventTime: AnalyticsListener.EventTime, count: Int, elapsedMs: Long) {
            droppedFrames += count
        }

        override fun onVideoDecoderInitialized(
            eventTime: AnalyticsListener.EventTime, decoderName: String, initializedTimestampMs: Long, initializationDurationMs: Long,
        ) {
            this@ExoEngine.decoderName = decoderName
        }
    }

    private fun send(type: String, vararg fields: Pair<String, Any?>) {
        val event = JSONObject().put("player", id).put("loadID", loadID).put("type", type)
        for ((key, value) in fields) event.putOpt(key, value)
        LumioCore.playerEvent(event)
    }

    companion object {
        /** ExoPlayer's error, as the core's failure kinds (EngineFailure.Kind). */
        fun classify(error: PlaybackException): Pair<String, Int?> {
            val cause = error.cause
            if (cause is HttpDataSource.InvalidResponseCodeException) return "http" to cause.responseCode
            return when (error.errorCode) {
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT -> "timeout" to null
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
                PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
                PlaybackException.ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED -> "network" to null
                PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW -> "stalled" to null
                PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
                PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED,
                PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
                PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES -> "unsupported" to null
                PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
                PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
                PlaybackException.ERROR_CODE_DECODING_FAILED -> "decoder" to null
                else -> "unknown" to null
            }
        }
    }
}

/** The app's engines by player name ("main"), made when the core first asks for one. */
object PlayerEngines {
    private lateinit var context: Context
    private val engines = mutableMapOf<String, ExoEngine>()

    fun init(context: Context) {
        this.context = context.applicationContext
    }

    fun engine(player: String): ExoEngine = engines.getOrPut(player) { ExoEngine(context, player) }

    /** A command from the core (on the UI thread); returns `{"result": …}`. */
    fun handle(json: String): String {
        val command = JSONObject(json)
        val result = runCatching { engine(command.getString("player")).handle(command) }.getOrNull()
        return JSONObject().put("result", result ?: JSONObject.NULL).toString()
    }
}
