package com.jackson.lumio.ui.settings

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.Button
import androidx.tv.material3.ListItem
import androidx.tv.material3.ListItemDefaults
import androidx.tv.material3.Tab
import androidx.tv.material3.TabRow
import androidx.tv.material3.Text
import com.jackson.lumio.BuildConfig
import com.jackson.lumio.core.AppSettings
import com.jackson.lumio.core.ContentCategory
import com.jackson.lumio.core.CoreException
import com.jackson.lumio.core.LumioCore
import com.jackson.lumio.core.Region
import com.jackson.lumio.core.Regions
import com.jackson.lumio.ui.LumioColors
import com.jackson.lumio.ui.common.MenuAction
import com.jackson.lumio.ui.common.OptionsPanel
import com.jackson.lumio.ui.common.RemoteTextField
import com.jackson.lumio.ui.providers.ProvidersScreen
import com.jackson.lumio.ui.providers.ProvidersViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** A sidebar section that can be switched off, by the key the core stores (the Mac's names where they match). */
enum class SidebarSection(val key: String, val title: String) {
    Live("liveTV", "Live TV"),
    Guide("guide", "Guide"),
    Movies("movies", "Movies"),
    Series("series", "Series"),
    Favorites("favorites", "Favorites"),
    Recents("recents", "Recents"),
    Search("search", "Search"),
}

/** Settings stored by the core (as on the Mac), and the Content tab's regions and hidden categories. */
class SettingsViewModel : ViewModel() {
    var settings by mutableStateOf<AppSettings?>(null)
        private set
    var regions by mutableStateOf<Regions?>(null)
        private set
    var hidden by mutableStateOf<List<ContentCategory>>(emptyList())
        private set
    var message by mutableStateOf<String?>(null)
        private set

    init {
        reload()
    }

    fun reload() {
        viewModelScope.launch { runCatching { LumioCore.settings() }.onSuccess { settings = it } }
    }

    fun reloadContent() {
        viewModelScope.launch {
            runCatching { LumioCore.regions() }.onSuccess { regions = it }
            runCatching { LumioCore.hiddenCategories() }.onSuccess { hidden = it }
        }
    }

    fun set(key: String, number: Double) = change { LumioCore.setSetting(key, number) }

    fun set(key: String, text: String) = change { LumioCore.setSetting(key, text) }

    fun setSectionShown(section: SidebarSection, shown: Boolean) {
        val current = settings?.hiddenSidebarItems.orEmpty()
        val next = if (shown) current - section.key else (current + section.key).distinct()
        change { LumioCore.setSetting("hiddenSidebarItems", next) }
    }

    fun setRegion(region: Region, shown: Boolean) = content { LumioCore.setRegion(region.code, shown) }

    fun setAllRegions(shown: Boolean) = content { LumioCore.setAllRegions(shown) }

    fun setGroup(category: ContentCategory, shown: Boolean) = content { LumioCore.setRegionCategory(category.provider, category.id, shown) }

    fun showAgain(category: ContentCategory) = content { LumioCore.setCategoryHidden(category.provider, category.kind, category.id, false) }

    private fun change(work: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                work()
                settings = LumioCore.settings()
                message = null
            } catch (error: CoreException) {
                message = error.message
            }
        }
    }

    private fun content(work: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                work()
                message = null
            } catch (error: CoreException) {
                message = error.message
            }
            reloadContent()
        }
    }
}

private enum class SettingsTab(val title: String) { Providers("Providers"), General("General"), Playback("Playback"), Content("Content"), About("About") }

private data class Picker(val title: String, val actions: List<MenuAction>)

/**
 * Settings, in tabs along the top: Providers, General (sidebar sections, refresh times), Playback
 * (format, buffer, reconnect, user agent), Content (Live TV regions and their groups, hidden
 * categories) and About (version and the third-party notices). Moving onto a tab shows it.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun SettingsScreen(providers: ProvidersViewModel, model: SettingsViewModel = viewModel()) {
    var tab by rememberSaveable { mutableStateOf(SettingsTab.Providers) }
    var picker by remember { mutableStateOf<Picker?>(null) }
    // Closing a picker gives the remote back to the row it was opened from.
    val pageFocus = remember { FocusRequester() }
    var hadPicker by remember { mutableStateOf(false) }
    LaunchedEffect(picker == null) {
        if (picker != null) hadPicker = true else if (hadPicker) {
            hadPicker = false
            runCatching { pageFocus.requestFocus() }
        }
    }
    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            // Coming up from a page, the remote lands on the tab that's showing.
            TabRow(selectedTabIndex = tab.ordinal, modifier = Modifier.padding(start = 32.dp, top = 24.dp, bottom = 8.dp).focusRestorer()) {
                SettingsTab.entries.forEach { entry ->
                    Tab(selected = entry == tab, onFocus = { tab = entry }) {
                        Text(entry.title, fontSize = 16.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                    }
                }
            }
            model.message?.let { Text(it, color = LumioColors.error, fontSize = 14.sp, modifier = Modifier.padding(horizontal = 32.dp)) }
            Box(Modifier.weight(1f)) {
                when (tab) {
                    SettingsTab.Providers -> ProvidersScreen(providers)
                    SettingsTab.General -> General(model, pageFocus) { picker = it }
                    SettingsTab.Playback -> Playback(model, pageFocus) { picker = it }
                    SettingsTab.Content -> Content(model, pageFocus)
                    SettingsTab.About -> About()
                }
            }
        }
        picker?.let { shown ->
            key(shown) { OptionsPanel(shown.title, shown.actions, onDismiss = { if (picker === shown) picker = null }) }
        }
    }
}

// MARK: Rows

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun Page(focus: FocusRequester? = null, content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    LazyColumn(
        Modifier.fillMaxSize().then(if (focus != null) Modifier.focusRequester(focus) else Modifier).focusRestorer(),
        contentPadding = PaddingValues(start = 32.dp, end = 32.dp, top = 8.dp, bottom = 48.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
        content = content,
    )
}

@Composable
private fun Heading(text: String) {
    Text(text, fontSize = 18.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(top = 16.dp, bottom = 4.dp))
}

@Composable
private fun Note(text: String) {
    Text(text, color = LumioColors.secondaryText, fontSize = 14.sp, modifier = Modifier.padding(vertical = 6.dp).width(640.dp))
}

/** A setting with its value on the right; OK opens [onClick] (a picker, or a switch). */
@Composable
private fun SettingRow(title: String, value: String, detail: String? = null, onClick: () -> Unit, onLongClick: (() -> Unit)? = null) {
    ListItem(
        selected = false,
        onClick = onClick,
        onLongClick = onLongClick,
        headlineContent = { Text(title, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = detail?.let { { Text(it, color = LumioColors.secondaryText, fontSize = 13.sp, maxLines = 2, overflow = TextOverflow.Ellipsis) } },
        trailingContent = { Text(value, color = LumioColors.accent, fontSize = 16.sp) },
        colors = ListItemDefaults.colors(),
        modifier = Modifier.width(680.dp),
    )
}

private fun onOff(on: Boolean) = if (on) "On" else "Off"

/** A picker over the page: each choice sets [onPick], the current one ticked. */
private fun <T> picker(title: String, choices: List<Pair<String, T>>, current: T, onPick: (T) -> Unit) =
    Picker(title, choices.map { (label, value) -> MenuAction(label, selected = value == current) { onPick(value) } })

// MARK: General

@Composable
private fun General(model: SettingsViewModel, focus: FocusRequester, pick: (Picker) -> Unit) {
    val settings = model.settings ?: return
    Page(focus) {
        item { Heading("Sidebar") }
        items(SidebarSection.entries) { section ->
            val shown = section.key !in settings.hiddenSidebarItems
            SettingRow(section.title, onOff(shown), onClick = { model.setSectionShown(section, !shown) })
        }
        item { Note("Switch off the sections you don't use. Settings always stays in the sidebar.") }
        item { Heading("Refresh") }
        item {
            val hours = settings.epgRefreshHours.toInt()
            SettingRow("Refresh the guide every", "$hours h", onClick = {
                pick(picker("Refresh the guide every", listOf(2, 4, 6, 8, 12, 24, 48).map { "$it h" to it.toDouble() },
                    settings.epgRefreshHours) { model.set("epgRefreshHours", it) })
            })
        }
        item {
            val hours = settings.catalogRefreshHours.toInt()
            SettingRow("Refresh channels, movies and series every", "$hours h", onClick = {
                pick(picker("Refresh channels, movies and series every", listOf(2, 4, 6, 12, 24, 48, 72).map { "$it h" to it.toDouble() },
                    settings.catalogRefreshHours) { model.set("catalogRefreshHours", it) })
            })
        }
        item {
            val days = settings.epgFutureDays.toInt()
            SettingRow("Keep upcoming programmes for", "$days day${if (days == 1) "" else "s"}", onClick = {
                pick(picker("Keep upcoming programmes for", listOf(1, 2, 3, 5, 7, 10, 14).map { "$it day${if (it == 1) "" else "s"}" to it.toDouble() },
                    settings.epgFutureDays) { model.set("epgFutureDays", it) })
            })
        }
        item { Note("Refreshes run in the background; Lumio always opens with what it already has. Fewer days of guide use less storage.") }
    }
}

// MARK: Playback

private val formats = listOf("MPEG-TS (.ts)" to "ts", "HLS (.m3u8)" to "m3u8")
private val buffers = listOf("Low latency" to "lowLatency", "Normal" to "normal", "Large (unstable network)" to "large")

@Composable
private fun Playback(model: SettingsViewModel, focus: FocusRequester, pick: (Picker) -> Unit) {
    val settings = model.settings ?: return
    var agent by remember(settings.userAgent) { mutableStateOf(settings.userAgent) }
    Page(focus) {
        item { Heading("Streams") }
        item {
            SettingRow("Preferred live format", formats.first { it.second == settings.preferredFormat }.first, onClick = {
                pick(picker("Preferred live format", formats, settings.preferredFormat) { model.set("preferredFormat", it) })
            })
        }
        item { Note("If a channel fails, Lumio tries the other format, then another provider that has the channel.") }
        item {
            SettingRow("Buffer", buffers.firstOrNull { it.second == settings.bufferPreset }?.first ?: settings.bufferPreset, onClick = {
                pick(picker("Buffer", buffers, settings.bufferPreset) { model.set("bufferPreset", it) })
            })
        }
        item {
            val seconds = settings.stallTimeoutSeconds.toInt()
            SettingRow("Reconnect after", "$seconds s without data", onClick = {
                pick(picker("Reconnect after", listOf(3, 5, 8, 10, 15, 20, 30).map { "$it s" to it.toDouble() },
                    settings.stallTimeoutSeconds) { model.set("stallTimeoutSeconds", it) })
            })
        }
        item { Heading("User agent") }
        item {
            RemoteTextField(label = null, value = agent, placeholder = settings.defaultUserAgent, imeAction = ImeAction.Done,
                modifier = Modifier.width(680.dp).onFocusChanged { if (!it.hasFocus && agent != settings.userAgent) model.set("userAgent", agent) },
                onChange = { agent = it })
        }
        item { Note("Some providers only accept certain players. Leave empty for the default. Changes apply from the next channel.") }
    }
}

// MARK: Content

@Composable
private fun Content(model: SettingsViewModel, focus: FocusRequester) {
    LaunchedEffect(Unit) { model.reloadContent() }
    val regions = model.regions
    var open by remember { mutableStateOf<Region?>(null) }
    var wasOpen by remember { mutableStateOf(false) }
    LaunchedEffect(open == null) {
        if (open != null) wasOpen = true else if (wasOpen) {
            wasOpen = false
            runCatching { focus.requestFocus() }
        }
    }
    Page(focus) {
        item { Heading("Live TV regions") }
        when {
            regions == null -> item { Note("Loading…") }
            regions.regions.isEmpty() -> item { Note("Your providers haven't listed any groups yet.") }
            else -> {
                item {
                    val shown = regions.regions.count { it.shown }
                    Row(Modifier.padding(vertical = 6.dp)) {
                        Button(onClick = { model.setAllRegions(true) }) { Text("Show all") }
                        Button(onClick = { model.setAllRegions(false) }, modifier = Modifier.padding(start = 12.dp)) { Text("Hide all") }
                        Text("$shown of ${regions.regions.size} shown", color = LumioColors.secondaryText, fontSize = 14.sp,
                            modifier = Modifier.padding(start = 16.dp, top = 12.dp))
                    }
                }
                items(regions.regions, key = { it.code }) { region ->
                    val partial = if (region.shown) region.shownCategories < region.categoryCount else region.shownCategories > 0
                    val detail = listOfNotNull("${region.groups} group${if (region.groups == 1) "" else "s"}",
                        if (partial) "${region.shownCategories} of ${region.categoryCount} shown" else null,
                        region.examples.takeIf { it.isNotEmpty() }?.let { "e.g. " + it.joinToString(", ") }).joinToString("  ·  ")
                    SettingRow(if (region.other) "Other groups" else "${region.name} (${region.code})", onOff(region.shown), detail,
                        onClick = { model.setRegion(region, !region.shown) }, onLongClick = { open = region })
                }
                item {
                    Note("OK switches a region on or off: its channels leave Live TV, the guide and Search. Hold OK to switch single groups. " +
                        "Movies and Series aren't affected; hold OK on a category there to hide it. Favorites and Recents still show what you picked.")
                }
            }
        }
        item { Heading("Hidden categories") }
        if (model.hidden.isEmpty()) {
            item { Note("Nothing hidden. Categories you hide in Movies or Series are listed here.") }
        } else {
            items(model.hidden, key = { "${it.provider}|${it.kind}|${it.id}" }) { category ->
                val kind = when (category.kind) { "movie" -> "Movies"; "series" -> "Series"; else -> "Live TV" }
                SettingRow(category.name, "Show again", "$kind  ·  ${category.providerName}", onClick = { model.showAgain(category) })
            }
        }
    }
    // A region's groups, each with its own switch; the list stays open while switching.
    open?.let { region ->
        val groups = model.regions?.categories?.get(region.code).orEmpty()
        OptionsPanel(
            title = if (region.other) "Other groups" else region.name,
            actions = groups.map { group ->
                MenuAction(group.name, selected = group.shown) { model.setGroup(group, !group.shown) }
            },
            onDismiss = { open = null },
            closeOnChoice = false,
            detail = { Text("OK switches a group on or off. Back when done.", color = LumioColors.secondaryText, fontSize = 14.sp) },
        )
    }
}

// MARK: About

@Composable
private fun About() {
    val context = LocalContext.current
    val notices by produceState<List<String>>(emptyList()) { value = readNotices(context) }
    Page {
        item { Text("Lumio for Android TV", fontSize = 24.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp)) }
        item {
            Note("Version ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}). An IPTV player for Xtream Codes providers. " +
                "Lumio only talks to your providers (and loads their logos and posters); there's no tracking of any kind.")
        }
        item { Heading("Acknowledgements") }
        item { Note("Lumio is built with these open-source components. Their licences follow; move down to read them.") }
        // One focusable paragraph at a time, so the remote can scroll through the whole text.
        items(notices) { paragraph -> Paragraph(paragraph) }
    }
}

@Composable
private fun Paragraph(text: String) {
    ListItem(
        selected = false,
        onClick = {},
        headlineContent = { Text(text, fontSize = 13.sp, color = LumioColors.text) },
        colors = ListItemDefaults.colors(focusedContainerColor = LumioColors.raised, focusedContentColor = LumioColors.text),
        modifier = Modifier.fillMaxWidth(),
    )
}

/** THIRD-PARTY-NOTICES.md from the app's assets, in paragraphs, without Markdown symbols. */
private suspend fun readNotices(context: Context): List<String> = withContext(Dispatchers.IO) {
    runCatching {
        context.assets.open("THIRD-PARTY-NOTICES.md").bufferedReader().readText()
            .split(Regex("\\n\\s*\\n"))
            .map { it.trim().removePrefix("### ").removePrefix("## ").removePrefix("# ").replace("**", "").replace("`", "") }
            .filter { it.isNotEmpty() && !it.startsWith("---") }
    }.getOrDefault(listOf("The notices couldn't be read."))
}
