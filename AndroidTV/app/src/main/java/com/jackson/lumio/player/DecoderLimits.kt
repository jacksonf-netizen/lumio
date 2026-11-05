package com.jackson.lumio.player

import android.app.ActivityManager
import android.content.Context
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.os.Build
import android.util.Log

/**
 * How many videos this device can decode at once, for multiview: read from what its H.264
 * hardware decoder reports, not a fixed number.
 *
 * - The decoder's instance limit (`maxSupportedInstances`), less one kept spare: some devices
 *   report the limit but the last instance fails to start.
 * - How much it can decode per second: each tile counts as a 1080p stream at 30 frames a second
 *   (most IPTV channels; tiles still decode the full stream whatever their size on screen). Read
 *   from the decoder's performance points (Android 10+) or, failing that, the fastest frame rate it
 *   claims at 1080p.
 * - Devices Android calls low-RAM (the onn HD stick, 1.5 GB) get at most 2 tiles.
 *
 * Asking for one more tile than the decoder can open fails that tile with a clear message (see
 * ExoEngine's `noFreeDecoder`), never a frozen picture.
 */
data class DecoderLimits(
    /** 1 means multiview isn't offered. */
    val maxTiles: Int,
    /** The decoder the numbers come from, or null if there's no hardware H.264 decoder. */
    val decoder: String?,
    /** Why the limit is what it is, for Settings → About and the logs. */
    val reason: String,
) {
    companion object {
        private const val TAG = "LumioDecoders"
        private const val MIME = "video/avc"

        @Volatile private var cached: DecoderLimits? = null
        /** Debug builds: a tile count from the launch extras (`-e multiviewTiles 4`), for the emulator. */
        @Volatile var override: Int? = null

        fun of(context: Context): DecoderLimits {
            override?.let { return DecoderLimits(it.coerceIn(1, 4), null, "set by the launch extras (debug build)") }
            return cached ?: read(context).also {
                cached = it
                Log.i(TAG, "Multiview: up to ${it.maxTiles} tiles (${it.reason})")
            }
        }

        private fun read(context: Context): DecoderLimits {
            val lowRam = context.getSystemService(ActivityManager::class.java).isLowRamDevice
            val info = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
                .filter { !it.isEncoder && it.supportedTypes.any { type -> type.equals(MIME, ignoreCase = true) } }
                .firstOrNull(::isHardware)
                ?: return DecoderLimits(1, null, "no hardware H.264 decoder")
            val caps = info.getCapabilitiesForType(MIME)
            val instances = caps.maxSupportedInstances
            val byInstances = if (instances > 2) instances - 1 else instances
            val byRate = tilesByRate(caps)
            val byMemory = if (lowRam) 2 else 4
            val tiles = minOf(byInstances, byRate, byMemory, 4).coerceAtLeast(1)
            val reason = buildString {
                append("${info.name}: $instances instances, about $byRate 1080p30 streams at once")
                if (lowRam) append(", low-RAM device")
            }
            return DecoderLimits(tiles, info.name, reason)
        }

        private fun isHardware(info: MediaCodecInfo): Boolean {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return info.isHardwareAccelerated && !info.isSoftwareOnly
            val name = info.name.lowercase()
            return !name.startsWith("omx.google.") && !name.startsWith("c2.android.") && !name.contains(".sw.")
        }

        /** 1080p30 streams the decoder can keep up with. */
        private fun tilesByRate(caps: MediaCodecInfo.CodecCapabilities): Int {
            val video = caps.videoCapabilities ?: return 1
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val points = video.supportedPerformancePoints
                if (!points.isNullOrEmpty()) {
                    // The most 1080p30 streams whose total some performance point covers. A point caps
                    // the frame rate too (a 4K60 decoder doesn't "cover" 1080p at 120 fps), so the same
                    // load is also asked for as one bigger picture at 30 fps.
                    return (4 downTo 1).firstOrNull { n ->
                        val faster = MediaCodecInfo.VideoCapabilities.PerformancePoint(1920, 1080, 30 * n)
                        val bigger = when (n) {
                            4 -> MediaCodecInfo.VideoCapabilities.PerformancePoint(3840, 2160, 30)
                            else -> MediaCodecInfo.VideoCapabilities.PerformancePoint(1920, 1080 * n, 30)
                        }
                        points.any { it.covers(faster) || it.covers(bigger) }
                    } ?: 1
                }
            }
            if (!video.isSizeSupported(1920, 1080)) return 1
            val fastest = runCatching { video.getSupportedFrameRatesFor(1920, 1080).upper }.getOrDefault(30.0)
            return (fastest / 30).toInt().coerceIn(1, 4)
        }
    }
}
