package com.jackson.lumio.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.graphics.Color
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.darkColorScheme

/**
 * Lumio's colours: the Mac's dark-mode greys, so both apps look alike, with the cyan of the app
 * icon's TV as the one accent. The highlight (where the remote is) is always cyan: an outline on
 * rows and posters, a fill on buttons.
 */
object LumioColors {
    /** Behind everything: the Mac's window background in dark mode. */
    val background = Color(0xFF1E1E1E)
    /** The rail and side panels. */
    val surface = Color(0xFF282828)
    /** Rows, cards and fields at rest. */
    val raised = Color(0xFF323232)
    /** A row or card under the highlight: the Mac's selected-row grey. */
    val focus = Color(0xFF464646)
    /** Thin lines between things. */
    val outline = Color(0xFF3A3A3A)
    /** The icon's cyan: the highlight, the current section, progress. */
    val accent = Color(0xFF2EE6F2)
    /** Text on a cyan fill. */
    val onAccent = Color(0xFF111111)
    val text = Color(0xFFEBEBEB)
    val secondaryText = Color(0xFF9E9E9E)
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
