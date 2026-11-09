package com.jackson.lumio.ui.player

import androidx.compose.foundation.background
import com.jackson.lumio.ui.common.LumioListItem
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Text
import com.jackson.lumio.core.Track
import com.jackson.lumio.ui.LumioColors

/** Audio and subtitle tracks, on the right of the video. Back closes it. */
@Composable
fun TracksPanel(tracks: List<Track>, onSelect: (kind: String, id: Int?) -> Unit) {
    val first = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
    val audio = tracks.filter { it.kind == "audio" }
    val subtitles = tracks.filter { it.kind == "subtitle" }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.CenterEnd) {
        LazyColumn(
            Modifier.width(420.dp).fillMaxHeight().background(LumioColors.surface.copy(alpha = 0.95f)).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            item { Heading("Audio") }
            if (audio.isEmpty()) item { Text("No choice of audio on this channel", color = LumioColors.secondaryText) }
            items(audio.size) { index ->
                val track = audio[index]
                Row(track.name, track.selected, Modifier.then(if (index == 0) Modifier.focusRequester(first) else Modifier)) {
                    onSelect("audio", track.id)
                }
            }
            item { Heading("Subtitles") }
            item {
                Row("Off", subtitles.none { it.selected }, if (audio.isEmpty()) Modifier.focusRequester(first) else Modifier) {
                    onSelect("subtitle", null)
                }
            }
            items(subtitles, key = { it.id }) { track -> Row(track.name, track.selected) { onSelect("subtitle", track.id) } }
        }
    }
}

@Composable
private fun Heading(text: String) {
    Text(text, color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 12.dp, bottom = 6.dp))
}

@Composable
private fun Row(name: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    LumioListItem(
        selected = selected,
        onClick = onClick,
        headlineContent = { Text(name) },
        trailingContent = if (selected) ({ Text("✓", color = LumioColors.accent) }) else null,
        modifier = modifier.fillMaxWidth(),
    )
}
