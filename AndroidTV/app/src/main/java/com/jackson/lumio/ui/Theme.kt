package com.jackson.lumio.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.darkColorScheme

/** Colours close to the Mac app's dark look: near-black surfaces, one blue accent. */
object LumioColors {
    val background = Color(0xFF121216)
    val surface = Color(0xFF1C1C22)
    val raised = Color(0xFF26262E)
    val accent = Color(0xFF3D8BFF)
    val text = Color(0xFFECECF1)
    val secondaryText = Color(0xFF9A9AA6)
    val warning = Color(0xFFFFB340)
    val error = Color(0xFFFF6B6B)
    val good = Color(0xFF4CC38A)
}

@Composable
fun LumioTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = LumioColors.accent,
            onPrimary = Color.White,
            background = LumioColors.background,
            onBackground = LumioColors.text,
            surface = LumioColors.surface,
            onSurface = LumioColors.text,
            surfaceVariant = LumioColors.raised,
            onSurfaceVariant = LumioColors.secondaryText,
            error = LumioColors.error,
        ),
        content = content,
    )
}
