package com.jackson.lumio

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.jackson.lumio.ui.LumioApp
import com.jackson.lumio.ui.LumioTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            LumioTheme {
                LumioApp()
            }
        }
    }
}
