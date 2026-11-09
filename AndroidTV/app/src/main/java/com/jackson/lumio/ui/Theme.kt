package com.jackson.lumio.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.graphics.Color
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.darkColorScheme

/**
 * Lumio's colours, taken from the app icon: a deep navy and the cyan of its glowing TV. The
 * highlight (where the remote is) is always cyan: an outline on rows and posters, a fill on buttons.
 */
object LumioColors {
    /** Behind everything; darker than the icon's navy so posters and logos stand out. */
    val background = Color(0xFF060C1C)
    /** The rail and side panels: the icon's navy. */
    val surface = Color(0xFF0A142F)
    /** Rows, cards and fields at rest. */
    val raised = Color(0xFF12203F)
    /** A row or card under the highlight. */
    val focus = Color(0xFF1A2D58)
    /** Thin lines between things. */
    val outline = Color(0xFF223358)
    /** The icon's cyan: the highlight, the current section, progress. */
    val accent = Color(0xFF2EE6F2)
    /** Text on a cyan fill. */
    val onAccent = Color(0xFF04112A)
    val text = Color(0xFFEAF2FF)
    val secondaryText = Color(0xFF8E9DBF)
    val warning = Color(0xFFFFB340)
    val error = Color(0xFFFF6B6B)
    val good = Color(0xFF4CC38A)
}

/** The theme, drawn at the size chosen in Settings → Display ([DisplaySizes]). */
@Composable
fun LumioTheme(content: @Composable () -> Unit) {
    val system = LocalDensity.current
    val scale = DisplaySizes.current.scale
    CompositionLocalProvider(LocalDensity provides Density(system.density * scale, system.fontScale)) {
        LumioColorScheme(content)
    }
}

@Composable
private fun LumioColorScheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = LumioColors.accent,
            onPrimary = LumioColors.onAccent,
            secondaryContainer = LumioColors.raised,
            onSecondaryContainer = LumioColors.accent,
            background = LumioColors.background,
            onBackground = LumioColors.text,
            surface = LumioColors.surface,
            onSurface = LumioColors.text,
            surfaceVariant = LumioColors.raised,
            onSurfaceVariant = LumioColors.secondaryText,
            // Components left on their defaults still highlight in Lumio's colours.
            inverseSurface = LumioColors.focus,
            inverseOnSurface = LumioColors.text,
            border = LumioColors.accent,
            borderVariant = LumioColors.outline,
            error = LumioColors.error,
        ),
        content = content,
    )
}
