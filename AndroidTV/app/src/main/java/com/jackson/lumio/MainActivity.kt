package com.jackson.lumio

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.lifecycle.lifecycleScope
import com.jackson.lumio.core.LumioCore
import kotlinx.coroutines.launch
import com.jackson.lumio.ui.LumioApp
import com.jackson.lumio.ui.LumioTheme

class MainActivity : ComponentActivity() {
    /**
     * Debug builds only, for testing on the emulator or a TV without typing on the remote:
     * `adb shell am start -n com.jackson.lumio/.MainActivity -e server URL -e username U -e password P`
     * adds that provider if none exists yet. Release builds ignore the extras.
     */
    private fun addTestProvider() {
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
