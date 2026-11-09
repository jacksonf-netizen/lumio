package com.jackson.lumio.update

import android.app.Application
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.jackson.lumio.BuildConfig
import com.jackson.lumio.core.CoreException
import com.jackson.lumio.core.LumioCore
import com.jackson.lumio.core.UpdateInfo
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Where an update is up to. */
sealed interface UpdateState {
    data object Idle : UpdateState
    data object Checking : UpdateState
    data class UpToDate(val latest: String) : UpdateState
    data class Available(val info: UpdateInfo) : UpdateState
    /** [fraction] null until the size is known. */
    data class Downloading(val info: UpdateInfo, val fraction: Float?) : UpdateState
    /** Android needs the user to let Lumio install apps (once). */
    data class NeedsPermission(val info: UpdateInfo, val apk: File) : UpdateState
    /** Handed to Android, which shows its own Install prompt. */
    data class Installing(val info: UpdateInfo) : UpdateState
    data class Failed(val message: String) : UpdateState
}

/**
 * Updates, as on the Mac: the shared core asks GitHub for the latest release with an Android
 * build (Lumio-AndroidTV.apk) newer than this one, this downloads the APK and its .sig, the shared
 * core checks the signature with the release key (the Mac's), and only then does Android's
 * PackageInstaller see the file. Android shows its own Install prompt, and only accepts an APK
 * signed with the same key as the installed app.
 *
 * Checks once at launch (debug builds only with `-e checkUpdates true`), and from Settings → About.
 */
class UpdateViewModel(application: Application) : AndroidViewModel(application) {
    var state by mutableStateOf<UpdateState>(UpdateState.Idle)
        private set
    /** The update panel is up: an update was found, or one is being installed. */
    var prompt by mutableStateOf(false)
        private set

    private val preferences = application.getSharedPreferences("updates", Context.MODE_PRIVATE)
    /** The version asked about: this build's, or in debug builds `-e updateTestVersion 0.1.0` (to test updating). */
    private val version get() = (if (BuildConfig.DEBUG) versionOverride else null) ?: BuildConfig.VERSION_NAME
    private var job: Job? = null
    private var checkedAtLaunch = false

    val configured get() = BuildConfig.UPDATE_REPOSITORY.isNotBlank() && BuildConfig.UPDATE_PUBLIC_KEY.isNotBlank()

    init {
        viewModelScope.launch {
            InstallResults.flow.filterNotNull().collect { result ->
                InstallResults.flow.value = null
                // Success replaces the running app, so it never gets here. Anything else failed or was cancelled.
                if (state is UpdateState.Installing) {
                    state = if (result == InstallResults.CANCELLED) UpdateState.Idle else UpdateState.Failed("The update wasn't installed: $result")
                    if (state is UpdateState.Idle) prompt = false
                }
            }
        }
    }

    /** A few seconds after the app opens, so it never slows the start. */
    fun checkAtLaunch() {
        if (checkedAtLaunch || !configured) return
        checkedAtLaunch = true
        if (BuildConfig.DEBUG) testInstall?.let { test ->
            viewModelScope.launch {
                delay(3000)
                install(test)
            }
            return
        }
        // Development builds (emulator tests…) don't check unless asked to.
        if (BuildConfig.DEBUG && !debugCheckAtLaunch) return
        viewModelScope.launch {
            delay(5000)
            check(userInitiated = false)
        }
    }

    /** A background check stays quiet unless there's an update the user hasn't skipped. */
    fun check(userInitiated: Boolean) {
        if (state is UpdateState.Checking || state is UpdateState.Downloading || state is UpdateState.Installing) return
        if (!configured) {
            state = UpdateState.Failed("This build has no release feed, so it can't check for updates.")
            return
        }
        state = UpdateState.Checking
        job = viewModelScope.launch {
            state = try {
                val info = LumioCore.checkForUpdate(BuildConfig.UPDATE_REPOSITORY, version)
                Log.i(TAG, "Update check: ${info.status}, latest ${info.latest}")
                when {
                    !info.available -> UpdateState.UpToDate(info.latest)
                    !userInitiated && preferences.getString(SKIPPED, null) == info.latest -> UpdateState.Idle
                    else -> UpdateState.Available(info).also { prompt = true }
                }
            } catch (error: CoreException) {
                Log.w(TAG, "Update check failed: ${error.message}")
                if (userInitiated) UpdateState.Failed(error.message ?: "Couldn't check for updates.") else UpdateState.Idle
            }
        }
    }

    fun later() {
        prompt = false
        state = UpdateState.Idle
    }

    fun skip(info: UpdateInfo) {
        preferences.edit().putString(SKIPPED, info.latest).apply()
        later()
    }

    /** Stops a download, or closes a message. */
    fun dismiss() {
        job?.cancel()
        later()
    }

    /** Downloads, verifies and installs [info]'s APK. */
    fun install(info: UpdateInfo) {
        val apkURL = info.apkURL
        val signatureURL = info.signatureURL
        if (apkURL == null || signatureURL == null) {
            state = UpdateState.Failed("This release has no signed Android build.")
            return
        }
        prompt = true
        state = UpdateState.Downloading(info, null)
        job = viewModelScope.launch {
            try {
                val folder = File(getApplication<Application>().cacheDir, "updates").apply { deleteRecursively(); mkdirs() }
                val apk = File(folder, "Lumio-AndroidTV.apk")
                val signature = withContext(Dispatchers.IO) { download(signatureURL, File(folder, "Lumio-AndroidTV.apk.sig"), 4096) }
                    .readText()
                download(apkURL, apk, MAX_APK_BYTES) { fraction -> state = UpdateState.Downloading(info, fraction) }
                // An unsigned or changed APK never reaches Android.
                LumioCore.verifyUpdate(apk.path, signature, BuildConfig.UPDATE_PUBLIC_KEY)
                Log.i(TAG, "Update ${info.latest}: downloaded and verified (${apk.length()} bytes)")
                handOver(info, apk)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: CoreException) {
                state = UpdateState.Failed(error.message ?: "The update's signature doesn't match. It wasn't installed.")
            } catch (error: IOException) {
                state = UpdateState.Failed("The download failed (${error.message ?: error.javaClass.simpleName}).")
            }
        }
    }

    /** After the user comes back from allowing Lumio to install apps. */
    fun resumeAfterPermission() {
        val waiting = state as? UpdateState.NeedsPermission ?: return
        handOver(waiting.info, waiting.apk)
    }

    /** The system screen where Lumio is allowed to install apps (Google TV: Security & restrictions → Unknown sources). */
    fun permissionIntent(): Intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${BuildConfig.APPLICATION_ID}"))

    private fun handOver(info: UpdateInfo, apk: File) {
        val context = getApplication<Application>()
        if (!context.packageManager.canRequestPackageInstalls()) {
            state = UpdateState.NeedsPermission(info, apk)
            return
        }
        state = UpdateState.Installing(info)
        viewModelScope.launch {
            try {
                withContext(Dispatchers.IO) { commit(context, apk) }
            } catch (error: IOException) {
                state = UpdateState.Failed("Android couldn't start the installation (${error.message}).")
            }
        }
    }

    private suspend fun download(address: String, into: File, limit: Long, progress: ((Float?) -> Unit)? = null): File =
        withContext(Dispatchers.IO) {
            val connection = URL(address).openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = true // GitHub sends release files from another host
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("User-Agent", "Lumio/${BuildConfig.VERSION_NAME}")
            try {
                if (connection.responseCode != 200) throw IOException("HTTP ${connection.responseCode}")
                val total = connection.contentLengthLong.takeIf { it > 0 }
                if (total != null && total > limit) throw IOException("the file is unexpectedly large")
                var received = 0L
                var reported = -1
                connection.inputStream.use { input ->
                    into.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (isActive) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            received += count
                            if (received > limit) throw IOException("the file is unexpectedly large")
                            output.write(buffer, 0, count)
                            val percent = total?.let { (received * 100 / it).toInt() } ?: -1
                            if (progress != null && percent != reported) {
                                reported = percent
                                withContext(Dispatchers.Main) { progress(total?.let { received.toFloat() / it }) }
                            }
                        }
                    }
                }
                into
            } finally {
                connection.disconnect()
            }
        }

    companion object {
        /** Debug builds: check at launch (`-e checkUpdates true`). */
        @Volatile var debugCheckAtLaunch = false
        /** Debug builds: install this at launch instead of checking (`-e updateTestApk URL -e updateTestSignature URL`). */
        @Volatile var testInstall: UpdateInfo? = null
        @Volatile var versionOverride: String? = null

        private const val TAG = "LumioUpdate"
        private const val SKIPPED = "skippedVersion"
        /** The APK is about 31 MB. */
        private const val MAX_APK_BYTES = 200L shl 20

        /** Writes the APK into an installer session and commits it; Android answers through [InstallResultReceiver]. */
        private fun commit(context: Context, apk: File) {
            val installer = context.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                .apply { setAppPackageName(context.packageName) }
            val id = installer.createSession(params)
            installer.openSession(id).use { session ->
                session.openWrite("Lumio-AndroidTV.apk", 0, apk.length()).use { output ->
                    apk.inputStream().use { it.copyTo(output) }
                    session.fsync(output)
                }
                // Mutable so the installer can add its status to it.
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                val intent = Intent(context, InstallResultReceiver::class.java).setPackage(context.packageName)
                session.commit(PendingIntent.getBroadcast(context, id, intent, flags).intentSender)
            }
        }
    }
}

/** What Android's installer reported, for the view model (a null value is nothing new). */
object InstallResults {
    const val CANCELLED = "cancelled"
    val flow = MutableStateFlow<String?>(null)
}

/** Android's installer reports here: first that the user must confirm (it shows its prompt), then the outcome. */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
                confirm?.let { context.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            }
            PackageInstaller.STATUS_SUCCESS -> Log.i("LumioUpdate", "Installed")
            PackageInstaller.STATUS_FAILURE_ABORTED -> InstallResults.flow.value = InstallResults.CANCELLED
            else -> {
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "status $status"
                Log.w("LumioUpdate", "Install failed: $message")
                InstallResults.flow.value = message
            }
        }
    }
}
