package com.jackson.lumio

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.util.TypedValue
import android.view.KeyEvent
import android.view.View
import android.widget.ArrayAdapter
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import kotlin.concurrent.thread

/**
 * Phase 0 test screen: logs into a provider through the shared core, lists its channels and plays
 * the one picked with ExoPlayer. Timings go to logcat under the tag "LumioTest" so start-up, sync
 * and channel changes can be measured with `adb logcat -s LumioTest`.
 *
 * The server comes from the launch intent (`adb shell am start ... -e server URL -e username U
 * -e password P`); the default is the test harness on the Mac as the emulator sees it.
 */
class MainActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var list: ListView
    private lateinit var playerView: PlayerView
    private var player: ExoPlayer? = null
    private var channels: List<Pair<String, String>> = emptyList()
    private var playRequestedAt = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val created = SystemClock.elapsedRealtime()
        status = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setPadding(48, 32, 48, 16)
            text = "Starting the shared core…"
        }
        list = ListView(this).apply {
            setPadding(32, 0, 32, 32)
            setOnItemClickListener { _, _, position, _ -> play(position) }
        }
        playerView = PlayerView(this).apply {
            visibility = View.GONE
            useController = false
            setBackgroundColor(Color.BLACK)
        }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(18, 18, 22))
            addView(status)
            addView(list, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        setContentView(FrameLayout(this).apply {
            addView(column)
            addView(playerView, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        })

        val server = intent.getStringExtra("server") ?: "http://10.0.2.2:8098"
        val username = intent.getStringExtra("username") ?: "test"
        val password = intent.getStringExtra("password") ?: "test"
        val database = filesDir.resolve("lumio.sqlite").path
        thread(name = "lumio-core") {
            val start = LumioCore.call("start", "database" to database, "cache" to cacheDir.path)
            Log.i(TAG, "core started in ${SystemClock.elapsedRealtime() - created} ms after onCreate: $start")
            show("Signing in to $server…")
            val added = LumioCore.call("addProvider", "name" to "Test", "server" to server,
                "username" to username, "password" to password)
            Log.i(TAG, "provider synced: $added")
            val result = LumioCore.call("channels")
            val array = result.optJSONArray("channels")
            val loaded = (0 until (array?.length() ?: 0)).map {
                val channel = array!!.getJSONObject(it)
                channel.getString("name") to channel.getString("url")
            }
            val memory = LumioCore.call("memory").optLong("residentBytes") / (1024 * 1024)
            Log.i(TAG, "channels listed: ${loaded.size} in ${result.optInt("ms")} ms; resident memory $memory MB")
            // Full-text search (SQLite FTS5) and HTTPS through Swift's networking.
            Log.i(TAG, "search 'harness': ${LumioCore.call("search", "text" to "harness")}")
            Log.i(TAG, "update check over HTTPS: ${LumioCore.call("checkUpdates")}")
            val checks = LumioCore.call("icuChecks").optJSONArray("checks")
            for (i in 0 until (checks?.length() ?: 0)) Log.i(TAG, "ICU check: ${checks!!.getString(i)}")
            runOnUiThread {
                channels = loaded
                list.adapter = ArrayAdapter(this, android.R.layout.simple_list_item_1, loaded.map { it.first })
                list.requestFocus()
                val error = added.optString("error")
                status.text = if (error.isNotEmpty()) "Couldn't sign in: $error" else
                    "${loaded.size} channels, ${added.optInt("programmes")} programmes, " +
                        "${added.optInt("movies")} movies, ${added.optInt("series")} series " +
                        "(synced in ${added.optInt("ms")} ms). Pick a channel; Back stops it."
            }
        }
    }

    private fun play(position: Int) {
        val (name, url) = channels.getOrNull(position) ?: return
        playRequestedAt = SystemClock.elapsedRealtime()
        val player = player ?: ExoPlayer.Builder(this).build().also { created ->
            player = created
            playerView.player = created
            created.addListener(object : Player.Listener {
                override fun onRenderedFirstFrame() {
                    Log.i(TAG, "first frame after ${SystemClock.elapsedRealtime() - playRequestedAt} ms")
                }
                override fun onPlayerError(error: PlaybackException) {
                    Log.e(TAG, "playback error: ${error.errorCodeName}")
                    status.text = "Couldn't play: ${error.errorCodeName}"
                    stopPlayback()
                }
            })
        }
        Log.i(TAG, "playing $name")
        playerView.visibility = View.VISIBLE
        player.setMediaItem(MediaItem.fromUri(url))
        player.prepare()
        player.play()
    }

    private fun stopPlayback() {
        player?.stop()
        playerView.visibility = View.GONE
        list.requestFocus()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK && playerView.visibility == View.VISIBLE) {
            stopPlayback()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onStop() {
        super.onStop()
        stopPlayback()
    }

    override fun onDestroy() {
        player?.release()
        player = null
        super.onDestroy()
    }

    private fun show(text: String) = runOnUiThread { status.text = text }

    private companion object {
        const val TAG = "LumioTest"
    }
}
