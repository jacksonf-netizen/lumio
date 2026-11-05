package com.jackson.lumio.images

import android.app.ActivityManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.withContext

/**
 * Channel logos and posters, the Android counterpart of the Mac's ImageCache: only the URLs
 * providers give (no third-party services), web URLs only, never more than [MAX_IMAGE_BYTES],
 * decoded at the size shown, a memory cache sized for the device, and a disk cache capped at
 * [DISK_CAPACITY] (oldest files go first).
 */
object ImageLoader {
    private const val MAX_IMAGE_BYTES = 15 shl 20
    private const val DISK_CAPACITY = 150L shl 20

    private lateinit var folder: File
    private lateinit var memory: LruCache<String, Bitmap>
    /** Loads in progress, so a logo shown twice at once is fetched once. */
    private val inFlight = mutableMapOf<String, CompletableDeferred<Bitmap?>>()

    @OptIn(ExperimentalCoroutinesApi::class)
    private val network = Dispatchers.IO.limitedParallelism(4)

    fun init(context: Context) {
        if (::memory.isInitialized) return
        folder = File(context.cacheDir, "images").apply { mkdirs() }
        // About an eighth of what Android gives the app, at most 32 MB (the HD stick gets less).
        val appMegabytes = context.getSystemService(ActivityManager::class.java).memoryClass
        val bytes = (appMegabytes.coerceAtMost(256) shl 20) / 8
        memory = object : LruCache<String, Bitmap>(bytes.coerceAtMost(32 shl 20)) {
            override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount
        }
    }

    /** Already in memory at [sizePx], without waiting. */
    fun cached(url: String, sizePx: Int): Bitmap? = memory.get(key(url, sizePx))

    /** The image at [url], decoded to fit [sizePx] square, or null if it can't be had. */
    suspend fun load(url: String, sizePx: Int): Bitmap? {
        val key = key(url, sizePx)
        memory.get(key)?.let { return it }
        var mine = false
        val deferred = synchronized(inFlight) {
            inFlight.getOrPut(key) { mine = true; CompletableDeferred() }
        }
        if (!mine) return deferred.await()
        val bitmap = runCatching { withContext(network) { fetchAndDecode(url, sizePx) } }.getOrNull()
        if (bitmap != null) memory.put(key, bitmap)
        deferred.complete(bitmap)
        synchronized(inFlight) { inFlight.remove(key) }
        return bitmap
    }

    private fun key(url: String, sizePx: Int) = "$sizePx|$url"

    private fun fetchAndDecode(url: String, sizePx: Int): Bitmap? {
        val bytes = readDisk(url) ?: download(url)?.also { writeDisk(url, it) } ?: return null
        return decode(bytes, sizePx)
    }

    private fun download(address: String): ByteArray? {
        val url = runCatching { URL(address) }.getOrNull() ?: return null
        if (url.protocol != "http" && url.protocol != "https") return null
        val connection = url.openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000
        connection.readTimeout = 15_000
        try {
            if (connection.responseCode >= 400) return null
            if (connection.contentLengthLong > MAX_IMAGE_BYTES) return null
            // Redirects stay on web URLs (HttpURLConnection never follows them to other schemes).
            connection.inputStream.use { input ->
                val buffer = java.io.ByteArrayOutputStream()
                val chunk = ByteArray(16 * 1024)
                while (true) {
                    val read = input.read(chunk)
                    if (read < 0) break
                    buffer.write(chunk, 0, read)
                    if (buffer.size() > MAX_IMAGE_BYTES) return null
                }
                return buffer.toByteArray()
            }
        } finally {
            connection.disconnect()
        }
    }

    /** Decodes at display size so hundreds of logos don't hold full-size bitmaps. */
    private fun decode(bytes: ByteArray, sizePx: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= sizePx && bounds.outHeight / (sample * 2) >= sizePx) sample *= 2
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: return null
        val scale = sizePx.toFloat() / maxOf(decoded.width, decoded.height)
        if (scale >= 1f) return decoded
        return Bitmap.createScaledBitmap(decoded, maxOf(1, (decoded.width * scale).toInt()), maxOf(1, (decoded.height * scale).toInt()), true)
            .also { if (it !== decoded) decoded.recycle() }
    }

    // MARK: Disk cache

    private fun file(url: String): File {
        val digest = MessageDigest.getInstance("SHA-256").digest(url.toByteArray())
        return File(folder, digest.joinToString("") { "%02x".format(it) })
    }

    private fun readDisk(url: String): ByteArray? {
        val file = file(url)
        if (!file.exists()) return null
        file.setLastModified(System.currentTimeMillis())
        return runCatching { file.readBytes() }.getOrNull()
    }

    private fun writeDisk(url: String, bytes: ByteArray) {
        runCatching {
            val target = file(url)
            val temporary = File(folder, target.name + ".tmp")
            temporary.writeBytes(bytes)
            temporary.renameTo(target)
            trimDisk()
        }
    }

    private var lastTrim = 0L

    /** At most once a minute: removes the least recently used files until under the cap. */
    private fun trimDisk() {
        val now = System.currentTimeMillis()
        if (now - lastTrim < 60_000) return
        lastTrim = now
        val files = folder.listFiles().orEmpty().sortedBy { it.lastModified() }
        var total = files.sumOf { it.length() }
        for (file in files) {
            if (total <= DISK_CAPACITY) break
            total -= file.length()
            file.delete()
        }
    }
}
