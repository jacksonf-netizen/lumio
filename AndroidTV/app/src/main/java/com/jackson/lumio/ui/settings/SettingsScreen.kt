package com.jackson.lumio.ui.settings

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import com.jackson.lumio.BuildConfig
import com.jackson.lumio.R
import com.jackson.lumio.core.AppSettings
import com.jackson.lumio.core.ContentCategory
import com.jackson.lumio.core.CoreException
import com.jackson.lumio.core.LumioCore
import com.jackson.lumio.core.Region
import com.jackson.lumio.core.Regions
import com.jackson.lumio.ui.LumioColors
import com.jackson.lumio.ui.DisplaySize
import com.jackson.lumio.ui.DisplaySizes
import com.jackson.lumio.ui.player.GuidePreview
import com.jackson.lumio.ui.common.LumioListItem
import com.jackson.lumio.ui.common.LumioShapes
import com.jackson.lumio.ui.common.MenuAction
import com.jackson.lumio.ui.common.OptionsPanel
import com.jackson.lumio.ui.common.PageTitle
import com.jackson.lumio.ui.common.RemoteTextField
import com.jackson.lumio.ui.common.SectionHeading
import com.jackson.lumio.ui.providers.ProvidersPane
import com.jackson.lumio.ui.providers.ProvidersViewModel
import com.jackson.lumio.update.UpdateState
import com.jackson.lumio.update.UpdateViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * A rail section that can be switched off, by the key the core stores (the Mac's names). Favorites
 * and Recents aren't listed: on Android TV they're groups in Live TV, not rail sections.
 */
enum class SidebarSection(val key: String, val title: String) {
    Search("search", "Search"),
    Live("liveTV", "Live TV"),
    Movies("movies", "Movies"),
    Series("series", "Series"),
}

/** Settings stored by the core (as on the Mac), and the Content page's regions and hidden categories. */
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

/** The pages of Settings, listed down the left. */
private enum class SettingsPage(val title: String) {
    Providers("Providers"),
    Playback("Playback"),
    Guide("Guide and refresh"),
    Display("Display"),
    Content("Regions and categories"),
    About("About"),
}

/** A list of choices over the page; [detail] is a few lines under its title. */
data class Picker(val title: String, val actions: List<MenuAction>, val detail: String? = null, val closeOnChoice: Boolean = true)

/**
 * Settings in two panes, like the TV's own: the pages down the left, the one under the remote on
 * the right. Every setting is a row with its current value; OK opens its choices.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun SettingsScreen(
    providers: ProvidersViewModel,
    updates: UpdateViewModel,
    model: SettingsViewModel = viewModel(),
    /** Opens Live TV (after a new provider has loaded). */
    onWatch: () -> Unit = {},
) {
    var page by rememberSaveable { mutableStateOf(SettingsPage.Providers) }
    var picker by remember { mutableStateOf<Picker?>(null) }
    // Closing a picker gives the remote back to the row it was opened from.
    val paneFocus = remember { FocusRequester() }
    var hadPicker by remember { mutableStateOf(false) }
    LaunchedEffect(picker == null) {
        if (picker != null) hadPicker = true else if (hadPicker) {
            hadPicker = false
            runCatching { paneFocus.requestFocus() }
        }
    }
    val focusManager = LocalFocusManager.current
    Box(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxSize()) {
            Column(Modifier.width(380.dp).fillMaxHeight().padding(start = 40.dp, top = 36.dp, end = 20.dp)) {
                PageTitle("Settings", Modifier.padding(start = 16.dp, bottom = 28.dp))
                Column(Modifier.focusRestorer().focusGroup(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    SettingsPage.entries.forEach { entry ->
                        LumioListItem(
                            selected = entry == page,
                            onClick = { focusManager.moveFocus(FocusDirection.Right) },
                            headlineContent = { Text(entry.title, fontSize = 18.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                            modifier = Modifier.fillMaxWidth().onFocusChanged { if (it.isFocused) page = entry },
                        )
                    }
                }
            }
            // A thin line between the two panes.
            Box(Modifier.padding(vertical = 36.dp).width(1.dp).fillMaxHeight().background(LumioColors.outline))
            Box(Modifier.weight(1f).fillMaxHeight()) {
                when (page) {
                    SettingsPage.Providers -> ProvidersPane(providers, paneFocus, pick = { picker = it }, onWatch = onWatch)
                    SettingsPage.Playback -> Playback(model, paneFocus) { picker = it }
                    SettingsPage.Guide -> GuideAndRefresh(model, paneFocus) { picker = it }
                    SettingsPage.Display -> Display(model, paneFocus) { picker = it }
                    SettingsPage.Content -> Content(model, paneFocus) { picker = it }
                    SettingsPage.About -> About(updates, paneFocus)
                }
            }
        }
        picker?.let { shown ->
            key(shown) {
                OptionsPanel(
                    shown.title, shown.actions, onDismiss = { if (picker === shown) picker = null },
                    closeOnChoice = shown.closeOnChoice,
                    detail = shown.detail?.let { text -> { Text(text, color = LumioColors.secondaryText, fontSize = 15.sp) } },
                )
            }
        }
    }
}

// MARK: Building blocks

/** The right-hand pane: its [title], then rows. */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun SettingsPane(title: String, focus: FocusRequester?, message: String? = null, content: LazyListScope.() -> Unit) {
    LazyColumn(
        Modifier.fillMaxSize().then(if (focus != null) Modifier.focusRequester(focus) else Modifier).focusRestorer(),
        contentPadding = PaddingValues(start = 36.dp, end = 56.dp, top = 40.dp, bottom = 56.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        item { Text(title, fontSize = 24.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 16.dp, bottom = 20.dp)) }
        message?.let { item { Text(it, color = LumioColors.error, fontSize = 15.sp, modifier = Modifier.padding(start = 16.dp, bottom = 12.dp)) } }
        content()
    }
}

/** A heading between groups of rows. */
fun LazyListScope.heading(text: String) {
    item { SectionHeading(text, Modifier.padding(start = 16.dp, top = 24.dp, bottom = 6.dp)) }
}

/** A short explanation under some rows. */
fun LazyListScope.note(text: String) {
    item { Note(text) }
}

@Composable
private fun Note(text: String) {
    Text(text, color = LumioColors.secondaryText, fontSize = 14.sp, lineHeight = 20.sp,
        modifier = Modifier.padding(start = 16.dp, top = 10.dp, bottom = 6.dp).widthIn(max = 760.dp))
}

/** A setting: its name on the left, its current [value] on the right; OK opens [onClick] (choices, or a switch). */
@Composable
fun SettingRow(
    title: String,
    value: String,
    detail: String? = null,
    valueColor: Color = LumioColors.secondaryText,
    onLongClick: (() -> Unit)? = null,
    onClick: () -> Unit,
) {
    LumioListItem(
        selected = false,
        onClick = onClick,
        onLongClick = onLongClick,
        headlineContent = { Text(title, fontSize = 18.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = detail?.let { { Text(it, color = LumioColors.secondaryText, fontSize = 14.sp, maxLines = 2, overflow = TextOverflow.Ellipsis) } },
        trailingContent = if (value.isEmpty()) null else ({ Text(value, color = valueColor, fontSize = 17.sp, maxLines = 1) }),
        modifier = Modifier.fillMaxWidth(),
    )
}

/** An on/off setting: "On" in cyan, "Off" in grey. */
@Composable
private fun SwitchRow(title: String, on: Boolean, detail: String? = null, onLongClick: (() -> Unit)? = null, onClick: () -> Unit) =
    SettingRow(title, if (on) "On" else "Off", detail, valueColor = if (on) LumioColors.accent else LumioColors.secondaryText,
        onLongClick = onLongClick, onClick = onClick)

/** Choices for a setting: each sets [onPick], the current one ticked. */
private fun <T> picker(title: String, choices: List<Pair<String, T>>, current: T, onPick: (T) -> Unit) =
    Picker(title, choices.map { (label, value) -> MenuAction(label, selected = value == current) { onPick(value) } })

private fun plural(count: Int, one: String) = "$count $one${if (count == 1) "" else "s"}"

// MARK: Playback

private val formats = listOf("MPEG-TS (.ts)" to "ts", "HLS (.m3u8)" to "m3u8")
private val buffers = listOf("Low latency" to "lowLatency", "Normal" to "normal", "Large (unstable network)" to "large")

@Composable
private fun Playback(model: SettingsViewModel, focus: FocusRequester, pick: (Picker) -> Unit) {
    val settings = model.settings ?: return
    var agent by remember(settings.userAgent) { mutableStateOf(settings.userAgent) }
    SettingsPane("Playback", focus, model.message) {
        item {
            SettingRow("Live format", formats.first { it.second == settings.preferredFormat }.first) {
                pick(picker("Live format", formats, settings.preferredFormat) { model.set("preferredFormat", it) })
            }
        }
        item {
            SettingRow("Buffer", buffers.firstOrNull { it.second == settings.bufferPreset }?.first ?: settings.bufferPreset) {
                pick(picker("Buffer", buffers, settings.bufferPreset) { model.set("bufferPreset", it) })
            }
        }
        item {
            val seconds = settings.stallTimeoutSeconds.toInt()
            SettingRow("Reconnect after", "$seconds s without data") {
                pick(picker("Reconnect after", listOf(3, 5, 8, 10, 15, 20, 30).map { "$it s" to it.toDouble() },
                    settings.stallTimeoutSeconds) { model.set("stallTimeoutSeconds", it) })
            }
        }
        item {
            val context = LocalContext.current
            SwitchRow("Preview in Live TV", GuidePreview.enabled,
                "The highlighted channel plays in a small picture. OK makes it full screen, Back makes it small again.") {
                GuidePreview.set(context, !GuidePreview.enabled)
            }
        }
        note("If a channel won't play, Lumio tries the other format, then another provider that has it.")
        heading("User agent")
        item {
            Box(Modifier.padding(horizontal = 16.dp)) {
                RemoteTextField(label = null, value = agent, placeholder = settings.defaultUserAgent, imeAction = ImeAction.Done,
                    modifier = Modifier.fillMaxWidth().onFocusChanged { if (!it.hasFocus && agent != settings.userAgent) model.set("userAgent", agent) },
                    onChange = { agent = it })
            }
        }
        note("Only change this if your provider asks for a particular player. Empty uses the default.")
    }
}

// MARK: Guide and refresh

@Composable
private fun GuideAndRefresh(model: SettingsViewModel, focus: FocusRequester, pick: (Picker) -> Unit) {
    val settings = model.settings ?: return
    SettingsPane("Guide and refresh", focus, model.message) {
        item {
            val hours = settings.epgRefreshHours.toInt()
            SettingRow("Refresh the guide every", "$hours h") {
                pick(picker("Refresh the guide every", listOf(2, 4, 6, 8, 12, 24, 48).map { "$it h" to it.toDouble() },
                    settings.epgRefreshHours) { model.set("epgRefreshHours", it) })
            }
        }
        item {
            val hours = settings.catalogRefreshHours.toInt()
            SettingRow("Refresh channels and films every", "$hours h") {
                pick(picker("Refresh channels and films every", listOf(2, 4, 6, 12, 24, 48, 72).map { "$it h" to it.toDouble() },
                    settings.catalogRefreshHours) { model.set("catalogRefreshHours", it) })
            }
        }
        item {
            val days = settings.epgFutureDays.toInt()
            SettingRow("Keep upcoming programmes for", plural(days, "day")) {
                pick(picker("Keep upcoming programmes for", listOf(1, 2, 3, 5, 7, 10, 14).map { plural(it, "day") to it.toDouble() },
                    settings.epgFutureDays) { model.set("epgFutureDays", it) })
            }
        }
        note("Refreshes run in the background. Fewer days of guide take less space.")
    }
}

// MARK: Display

@Composable
private fun Display(model: SettingsViewModel, focus: FocusRequester, pick: (Picker) -> Unit) {
    val settings = model.settings ?: return
    val context = LocalContext.current
    SettingsPane("Display", focus, model.message) {
        item {
            val size = DisplaySizes.current
            SettingRow("Size", size.title) {
                pick(picker("Size", DisplaySize.entries.map { it.title to it }, size) { DisplaySizes.set(context, it) })
            }
        }
        note("How big text, rows and posters are. Larger is easier to read from across the room.")
        heading("Sections")
        items(SidebarSection.entries) { section ->
            val shown = section.key !in settings.hiddenSidebarItems
            SwitchRow(section.title, shown) { model.setSectionShown(section, !shown) }
        }
        note("Switch off what you don't use. Movies and Series share On Demand, which goes when both are off. Settings always stays.")
    }
}

// MARK: Regions and categories

@Composable
private fun Content(model: SettingsViewModel, focus: FocusRequester, pick: (Picker) -> Unit) {
    LaunchedEffect(Unit) { model.reloadContent() }
    val regions = model.regions
    SettingsPane("Regions and categories", focus, model.message) {
        when {
            regions == null -> note("Loading…")
            regions.regions.isEmpty() -> note("Your providers haven't listed any groups yet.")
            else -> {
                val shownCount = regions.regions.count { it.shown }
                item { SettingRow("Show every region", "$shownCount of ${regions.regions.size} on") { model.setAllRegions(true) } }
                item { SettingRow("Hide every region", "") { model.setAllRegions(false) } }
                heading("Live TV regions")
                items(regions.regions, key = { it.code }) { region ->
                    val partial = if (region.shown) region.shownCategories < region.categoryCount else region.shownCategories > 0
                    val detail = listOfNotNull(plural(region.groups, "group"),
                        if (partial) "${region.shownCategories} of ${region.categoryCount} on" else null,
                        region.examples.takeIf { it.isNotEmpty() }?.let { "e.g. " + it.joinToString(", ") }).joinToString("  ·  ")
                    SwitchRow(if (region.other) "Other groups" else "${region.name} (${region.code})", region.shown, detail,
                        onLongClick = { pick(regionGroups(model, region)) }) { model.setRegion(region, !region.shown) }
                }
                note("A region that's off leaves Live TV, the guide and Search. Hold OK on a region to switch single groups.")
            }
        }
        heading("Hidden categories")
        if (model.hidden.isEmpty()) {
            note("Nothing hidden. To hide a Movies or Series category, hold OK on it.")
        } else {
            items(model.hidden, key = { "${it.provider}|${it.kind}|${it.id}" }) { category ->
                val kind = when (category.kind) { "movie" -> "Movies"; "series" -> "Series"; else -> "Live TV" }
                SettingRow(category.name, "Show again", "$kind  ·  ${category.providerName}", valueColor = LumioColors.accent) {
                    model.showAgain(category)
                }
            }
        }
    }
}

/** A region's groups, each with its own switch; the list stays open while switching. */
private fun regionGroups(model: SettingsViewModel, region: Region): Picker {
    val groups = model.regions?.categories?.get(region.code).orEmpty()
    return Picker(
        title = if (region.other) "Other groups" else region.name,
        actions = groups.map { group -> MenuAction(group.name, selected = group.shown) { model.setGroup(group, !group.shown) } },
        detail = "OK switches a group on or off. Back when you're done.",
        closeOnChoice = false,
    )
}

// MARK: About

@Composable
private fun About(updates: UpdateViewModel, focus: FocusRequester) {
    var notices by remember { mutableStateOf(false) }
    if (notices) {
        Notices(onClose = { notices = false })
        return
    }
    SettingsPane("About", focus) {
        item {
            Row(Modifier.padding(start = 16.dp, bottom = 20.dp), verticalAlignment = Alignment.CenterVertically) {
                Image(painterResource(R.drawable.lumio_mark), contentDescription = null,
                    modifier = Modifier.size(72.dp).clip(RoundedCornerShape(16.dp)))
                Column(Modifier.padding(start = 20.dp)) {
                    Text("Lumio", fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
                    Text("Version ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", color = LumioColors.secondaryText, fontSize = 15.sp)
                }
            }
        }
        item {
            val status = when (val state = updates.state) {
                UpdateState.Checking -> "Checking…"
                is UpdateState.UpToDate -> "Up to date"
                is UpdateState.Available -> "${state.info.latest} available"
                is UpdateState.Downloading -> "Downloading…"
                is UpdateState.Installing -> "Installing…"
                is UpdateState.NeedsPermission -> "Waiting for permission"
                is UpdateState.Failed -> "Couldn't check"
                UpdateState.Idle -> if (updates.configured) "" else "No release feed"
            }
            val detail = (updates.state as? UpdateState.Failed)?.message
            SettingRow("Check for updates", status, detail,
                valueColor = if (updates.state is UpdateState.Available) LumioColors.accent else LumioColors.secondaryText) {
                updates.check(userInitiated = true)
            }
        }
        item { SettingRow("Open-source licences", "") { notices = true } }
        note("Lumio only talks to your providers (and where their logos and posters come from), and checks GitHub for updates. No tracking of any kind.")
    }
}

/** THIRD-PARTY-NOTICES.md, a paragraph at a time so the remote can move through it. Back closes it. */
@Composable
private fun Notices(onClose: () -> Unit) {
    val context = LocalContext.current
    val paragraphs by produceState<List<String>>(emptyList()) { value = readNotices(context) }
    val first = remember { FocusRequester() }
    BackHandler(onBack = onClose)
    LaunchedEffect(paragraphs.isNotEmpty()) { if (paragraphs.isNotEmpty()) runCatching { first.requestFocus() } }
    SettingsPane("Open-source licences", null) {
        note("Lumio is built with these open-source components. Back returns to About.")
        items(paragraphs.size) { index ->
            Surface(
                onClick = {},
                modifier = Modifier.fillMaxWidth().then(if (index == 0) Modifier.focusRequester(first) else Modifier),
                shape = ClickableSurfaceDefaults.shape(LumioShapes.row),
                colors = ClickableSurfaceDefaults.colors(
                    containerColor = Color.Transparent, contentColor = LumioColors.secondaryText,
                    focusedContainerColor = LumioColors.raised, focusedContentColor = LumioColors.text,
                ),
                scale = ClickableSurfaceDefaults.scale(focusedScale = 1f),
            ) {
                Text(paragraphs[index], fontSize = 14.sp, lineHeight = 20.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            }
        }
        item { Spacer(Modifier.height(24.dp)) }
    }
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
