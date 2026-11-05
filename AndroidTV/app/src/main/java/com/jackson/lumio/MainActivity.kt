package com.jackson.lumio

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.lifecycle.lifecycleScope
import com.jackson.lumio.core.LumioCore
import com.jackson.lumio.player.DecoderLimits
import com.jackson.lumio.core.UpdateInfo
import com.jackson.lumio.update.UpdateViewModel
import kotlinx.coroutines.launch
import com.jackson.lumio.ui.LumioApp
import com.jackson.lumio.ui.LumioTheme

class MainActivity : ComponentActivity() {
    /**
     * Debug builds only, for testing on the emulator or a TV without typing on the remote:
     * `adb shell am start -n com.jackson.lumio/.MainActivity -e server URL -e username U -e password P`
     * adds that provider if none exists yet. `-e multiviewTiles N` sets how many multiview tiles are
     * offered, in place of what the decoder reports (the emulator's decoders say little).
     * `-e checkUpdates true` checks for updates at launch, and `-e updateTestVersion 0.1.0` asks as
     * if that version were running (to try updating to the latest release); `-e updateTestApk URL
     * -e updateTestSignature URL` installs that APK at launch (to test the install path against a
     * local server). Release builds ignore the extras.
     */
    private fun addTestProvider() {
        intent.getStringExtra("multiviewTiles")?.toIntOrNull()?.let { DecoderLimits.override = it }
        if (intent.getStringExtra("checkUpdates") == "true") UpdateViewModel.debugCheckAtLaunch = true
        intent.getStringExtra("updateTestVersion")?.let { UpdateViewModel.versionOverride = it }
        val testApk = intent.getStringExtra("updateTestApk")
        val testSignature = intent.getStringExtra("updateTestSignature")
        if (testApk != null && testSignature != null) {
            UpdateViewModel.testInstall = UpdateInfo("available", "test", "Test update", null, null, testApk, testSignature)
        }
        val server = intent.getStringExtra("server") ?: return
        val username = intent.getStringExtra("username") ?: return
        val password = intent.getStringExtra("password") ?: return
        lifecycleScope.launch {
            runCatching {
                if (LumioCore.providers().isEmpty()) LumioCore.addProvider("Test", server, username, password)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (BuildConfig.DEBUG) addTestProvider()
        setContent {
            LumioTheme {
                LumioApp()
            }
        }
    }
}
