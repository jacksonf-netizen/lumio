package com.jackson.lumio.ui.search

import androidx.compose.foundation.layout.Arrangement
import com.jackson.lumio.ui.common.LumioListItem
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.Text
import com.jackson.lumio.core.Channel
import com.jackson.lumio.core.CoreException
import com.jackson.lumio.core.LumioCore
import com.jackson.lumio.core.ProgrammeHit
import com.jackson.lumio.core.SearchResults
import com.jackson.lumio.images.RemoteImage
import com.jackson.lumio.ui.LumioColors
import com.jackson.lumio.ui.common.MenuAction
import com.jackson.lumio.ui.common.RemoteTextField
import com.jackson.lumio.ui.vod.Panel
import com.jackson.lumio.ui.vod.PlayVOD
import com.jackson.lumio.ui.vod.PosterCard
import com.jackson.lumio.ui.vod.Shelf
import com.jackson.lumio.ui.vod.VODHost
import com.jackson.lumio.ui.vod.VODHostScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.Date

/** Search as you type, a moment after the last key. */
class SearchViewModel : ViewModel() {
    var query by mutableStateOf("")
        private set
    var results by mutableStateOf<SearchResults?>(null)
        private set
    var searching by mutableStateOf(false)
        private set
    var message by mutableStateOf<String?>(null)
        private set
    private var job: Job? = null

    fun update(text: String) {
        query = text
        job?.cancel()
        if (text.isBlank()) {
            results = null
            searching = false
            return
        }
        job = viewModelScope.launch {
            delay(300)
            searching = true
            try {
                results = LumioCore.search(text)
                message = null
            } catch (error: CoreException) {
                message = error.message
            }
            searching = false
        }
    }
}

/**
 * Search across channels, guide programmes, movies and series (the core's search, as on the Mac:
 * "sky spo" finds Sky Sports). A channel plays; a programme on now plays its channel, a later one
 * shows its details; a movie or series opens its page over the results.
 */
@Composable
fun SearchScreen(onWatch: (channel: String, group: String) -> Unit, onPlay: PlayVOD, playerShowing: Boolean) {
    val model: SearchViewModel = viewModel()
    VODHost(onPlay, playerShowing) { Results(model, this, onWatch) }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun Results(model: SearchViewModel, host: VODHostScope, onWatch: (String, String) -> Unit) {
    val results = model.results
    val context = LocalContext.current
    val timeFormat = android.text.format.DateFormat.getTimeFormat(context)
    // Watching from search zaps through every channel.
    val watch = { channel: Channel -> onWatch(channel.id, "all") }
    LazyColumn(
        Modifier.fillMaxSize().focusRestorer(),
        contentPadding = PaddingValues(top = 28.dp, bottom = 48.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item { Text("Search", fontSize = 28.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 32.dp)) }
        item {
            RemoteTextField(
                label = null, value = model.query, placeholder = "Channels, programmes, movies and series",
                imeAction = ImeAction.Search, startEditing = model.query.isEmpty(),
                modifier = Modifier.padding(horizontal = 32.dp).width(560.dp), onChange = model::update,
            )
        }
        when {
            model.query.isBlank() -> item {
                Hint("Type part of a name. \"sky spo\" finds Sky Sports; accents and capitals don't matter.")
            }
            model.message != null -> item { Hint(model.message!!) }
            results == null || (results.isEmpty && model.searching) -> item { Hint("Searching…") }
            results.isEmpty -> item { Hint("Nothing matches “${model.query}”.") }
            else -> {
                if (results.channels.isNotEmpty()) {
                    item { Heading("Channels") }
                    items(results.channels, key = { "c|${it.id}" }) { channel -> ChannelRow(channel) { watch(channel) } }
                }
                if (results.movies.isNotEmpty()) {
                    item(key = "movies") {
                        Shelf("Movies") {
                            items(results.movies, key = { "m|${it.provider}|${it.id}" }) { item ->
                                PosterCard(item, onClick = { host.openItem(item) }, onLongClick = { host.itemOptions(item) })
                            }
                        }
                    }
                }
                if (results.series.isNotEmpty()) {
                    item(key = "series") {
                        Shelf("Series") {
                            items(results.series, key = { "s|${it.provider}|${it.id}" }) { item ->
                                PosterCard(item, onClick = { host.openItem(item) }, onLongClick = { host.itemOptions(item) })
                            }
                        }
                    }
                }
                if (results.programmes.isNotEmpty()) {
                    item { Heading("On the guide") }
                    items(results.programmes, key = { "p|${it.programme.start}|${it.programme.title}|${it.channel?.id}" }) { hit ->
                        ProgrammeRow(hit, timeFormat) {
                            val now = System.currentTimeMillis() / 1000.0
                            val channel = hit.channel
                            if (channel != null && hit.programme.isOn(now)) watch(channel) else host.showPanel(details(hit, timeFormat, watch))
                        }
                    }
                }
            }
        }
    }
}

/** A later (or earlier) programme: its time and description, and its channel to watch now. */
private fun details(hit: ProgrammeHit, format: java.text.DateFormat, watch: (Channel) -> Unit): Panel {
    val programme = hit.programme
    val time = "${format.format(Date((programme.start * 1000).toLong()))} – ${format.format(Date((programme.stop * 1000).toLong()))}"
    val detail = listOfNotNull(listOfNotNull(time, hit.channel?.name, programme.episode).joinToString("  ·  "),
        programme.subtitle, programme.summary).joinToString("\n\n")
    return Panel(programme.title, listOfNotNull(hit.channel?.let { channel -> MenuAction("Watch ${channel.name} now") { watch(channel) } }),
        detail)
}

@Composable
private fun Heading(text: String) {
    Text(text, fontSize = 19.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(start = 32.dp, top = 8.dp))
}

@Composable
private fun Hint(text: String) {
    Text(text, color = LumioColors.secondaryText, fontSize = 17.sp, modifier = Modifier.padding(horizontal = 32.dp))
}

@Composable
private fun ChannelRow(channel: Channel, onClick: () -> Unit) {
    LumioListItem(
        selected = false,
        onClick = onClick,
        leadingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(channel.number?.toString() ?: "", color = LumioColors.secondaryText, fontSize = 15.sp, modifier = Modifier.width(48.dp))
                RemoteImage(channel.logo, 40.dp)
            }
        },
        headlineContent = { Text(channel.name, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        modifier = Modifier.padding(horizontal = 32.dp).width(640.dp),
    )
}

@Composable
private fun ProgrammeRow(hit: ProgrammeHit, format: java.text.DateFormat, onClick: () -> Unit) {
    val programme = hit.programme
    val now = System.currentTimeMillis() / 1000.0
    val time = when {
        programme.isOn(now) -> "On now"
        else -> format.format(Date((programme.start * 1000).toLong()))
    }
    LumioListItem(
        selected = false,
        onClick = onClick,
        headlineContent = { Text(programme.title, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            Column {
                Text(listOfNotNull(time, hit.channel?.name).joinToString("  ·  "),
                    color = if (programme.isOn(now)) LumioColors.accent else LumioColors.secondaryText, fontSize = 14.sp)
            }
        },
        modifier = Modifier.padding(horizontal = 32.dp).width(640.dp).fillMaxWidth(),
    )
}
