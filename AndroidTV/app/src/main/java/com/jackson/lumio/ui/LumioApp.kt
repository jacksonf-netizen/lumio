package com.jackson.lumio.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Icon
import androidx.tv.material3.Surface
import androidx.tv.material3.SurfaceDefaults
import androidx.tv.material3.Text
import com.jackson.lumio.R
import com.jackson.lumio.ui.guide.GuideScope
import com.jackson.lumio.ui.guide.GuideScreen
import com.jackson.lumio.ui.live.LiveTvScreen
import com.jackson.lumio.ui.multiview.MultiviewScreen
import com.jackson.lumio.ui.multiview.MultiviewViewModel
import com.jackson.lumio.ui.player.PlayerScreen
import com.jackson.lumio.ui.player.PlayerViewModel
import com.jackson.lumio.ui.providers.ProvidersViewModel
import com.jackson.lumio.ui.search.SearchScreen
import com.jackson.lumio.ui.settings.SettingsScreen
import com.jackson.lumio.ui.settings.SettingsViewModel
import com.jackson.lumio.ui.vod.OnDemandScreen
import com.jackson.lumio.update.UpdatePanel
import com.jackson.lumio.update.UpdateViewModel
import kotlinx.coroutines.delay

/**
 * The sections in the rail. Favorites and Recently Watched aren't here: they're the first groups
 * in Live TV and the guide. Movies and Series share On Demand.
 */
enum class Section(val title: String, val icon: Int) {
    Search("Search", R.drawable.ic_search),
    Live("Live TV", R.drawable.ic_live),
    Guide("Guide", R.drawable.ic_guide),
    OnDemand("On Demand", R.drawable.ic_ondemand),
    /** Always shown, at the bottom of the rail. */
    Settings("Settings", R.drawable.ic_settings),
}

/** The rail's width while folded (icons only) and while the remote is on it (icons and names). */
private val RailFolded = 72.dp
private val RailOpen = 216.dp

/**
 * The whole app: an icon rail on the left and the chosen section beside it. Moving onto the rail
 * opens it over the page with the sections' names; moving off folds it back to icons.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun LumioApp() {
    val providers: ProvidersViewModel = viewModel()
    val player: PlayerViewModel = viewModel()
    val multiview: MultiviewViewModel = viewModel()
    val updates: UpdateViewModel = viewModel()
    LaunchedEffect(Unit) { updates.checkAtLaunch() }
    // Back from allowing Lumio to install apps: carry on with the update.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) updates.resumeAfterPermission() }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    val settings: SettingsViewModel = viewModel()
    // Sections switched off in Settings → Sidebar leave the rail (the keys are the Mac's).
    val hidden = settings.settings?.hiddenSidebarItems.orEmpty()
    val vodKinds = listOfNotNull("movie".takeIf { "movies" !in hidden }, "series".takeIf { "series" !in hidden })
    val sections = Section.entries.filter {
        when (it) {
            Section.Search -> "search" !in hidden
            Section.Live -> "liveTV" !in hidden
            Section.Guide -> "guide" !in hidden
            Section.OnDemand -> vodKinds.isNotEmpty()
            Section.Settings -> true
        }
    }
    val state = providers.state
    var section by rememberSaveable { mutableStateOf(Section.Live) }
    // The first time, with no provider yet, Settings is where to start.
    var checkedFirstRun by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(state.loaded) {
        if (state.loaded && !checkedFirstRun) {
            checkedFirstRun = true
            if (state.providers.isEmpty()) section = Section.Settings
        }
    }
    val shown = if (section in sections) section else sections.first()
    // Back from a screen's content returns to the rail; Back on the rail leaves the app.
    val railFocus = remember { FocusRequester() }
    var railFocused by remember { mutableStateOf(false) }
    // Screens return the highlight to where it was when the player or multiview closes.
    val overlay = player.showing || multiview.showing
    BackHandler(enabled = !railFocused && !overlay) { runCatching { railFocus.requestFocus() } }
    // Resting on a section for a moment shows it, so passing over the others doesn't load them.
    // Not Search: it opens the keyboard, which would take the remote off the rail.
    var resting by remember { mutableStateOf<Section?>(null) }
    LaunchedEffect(resting) {
        val target = resting?.takeIf { it != Section.Search } ?: return@LaunchedEffect
        delay(300)
        section = target
    }
    // At launch the remote starts on the section that's showing, not the rail's first icon.
    LaunchedEffect(Unit) {
        delay(50)
        runCatching { railFocus.requestFocus() }
    }
    // Right (or OK) on the rail goes into the section: to where the remote last was there, else
    // its first row, rather than whatever happens to be level with the icon.
    val contentFocus = remember { FocusRequester() }
    var enter by remember { mutableStateOf(0) }
    LaunchedEffect(enter) {
        if (enter == 0) return@LaunchedEffect
        delay(150)
        runCatching { contentFocus.requestFocus() }
    }

    // A Surface gives everything inside the theme's text colour.
    Surface(colors = SurfaceDefaults.colors(containerColor = LumioColors.background, contentColor = LumioColors.text)) {
        Box(Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize().padding(start = RailFolded).focusRequester(contentFocus).focusRestorer().focusGroup()) {
                val play = { channel: String, group: String -> player.watch(channel, group) }
                val playing = player.state?.channel?.id
                val playVOD = { k: String, provider: String, id: String, position: Double?, title: String, subtitle: String? ->
                    player.playVOD(k, provider, id, position, title, subtitle)
                }
                when (shown) {
                    Section.Search -> SearchScreen(onWatch = play, onPlay = playVOD, playerShowing = overlay)
                    Section.Live -> LiveTvScreen(onPlay = play, playerShowing = overlay)
                    Section.Guide -> GuideScreen(GuideScope.All, play, overlay, playing)
                    Section.OnDemand -> OnDemandScreen(vodKinds, onPlay = playVOD, playerShowing = overlay)
                    Section.Settings -> SettingsScreen(providers, updates, settings)
                }
            }
            Rail(
                sections = sections,
                shown = shown,
                open = railFocused,
                syncSummary = state.syncSummary,
                focus = railFocus,
                content = contentFocus,
                onFocusChanged = { railFocused = it },
                onRest = { resting = it },
                onChoose = {
                    resting = null
                    section = it
                    enter++
                },
            )
        }
        if (player.showing) {
            PlayerScreen(player, onMultiview = if (multiview.available) ({
                val channel = player.state?.channel?.id
                val group = player.group
                player.dismiss()
                multiview.start(channel, group)
            }) else null)
        }
        // An update waits until nothing is playing.
        if (updates.prompt && !overlay) UpdatePanel(updates)
        if (multiview.showing) {
            MultiviewScreen(
                multiview,
                // Every tile's stream closes before the full-screen player opens its own.
                onFullScreen = { channel, group -> multiview.stop { player.watch(channel, group) } },
                onClose = { multiview.stop() },
            )
        }
    }
}

@Composable
private fun Rail(
    sections: List<Section>,
    shown: Section,
    open: Boolean,
    syncSummary: String?,
    focus: FocusRequester,
    content: FocusRequester,
    onFocusChanged: (Boolean) -> Unit,
    onRest: (Section) -> Unit,
    onChoose: (Section) -> Unit,
) {
    val width by animateDpAsState(if (open) RailOpen else RailFolded, tween(160), label = "rail")
    // The page dims behind the open rail.
    if (open) {
        Box(
            Modifier.fillMaxSize().background(
                Brush.horizontalGradient(0f to Color(0xF2060C1C), 0.45f to Color(0xB3060C1C), 1f to Color(0x66060C1C)),
            ),
        )
    }
    Column(
        Modifier
            .width(width)
            .fillMaxHeight()
            .background(LumioColors.surface)
            .clipToBounds()
            .onFocusChanged { onFocusChanged(it.hasFocus) }
            .focusGroup()
            .padding(horizontal = 10.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(Modifier.padding(start = 6.dp, bottom = 20.dp).height(40.dp), verticalAlignment = Alignment.CenterVertically) {
            Image(painterResource(R.drawable.lumio_mark), contentDescription = null, modifier = Modifier.size(40.dp).clip(RoundedCornerShape(9.dp)))
            if (open) {
                Text("Lumio", fontSize = 20.sp, fontWeight = FontWeight.SemiBold, softWrap = false,
                    modifier = Modifier.padding(start = 12.dp))
            }
        }
        for (item in sections) {
            if (item == Section.Settings) {
                Spacer(Modifier.weight(1f))
                if (open && syncSummary != null) {
                    Text(syncSummary, color = LumioColors.secondaryText, fontSize = 13.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(start = 12.dp, bottom = 8.dp).width(RailOpen - 44.dp))
                }
            }
            RailItem(
                item,
                selected = item == shown,
                open = open,
                // Only moving along the rail switches sections: arriving on it (Back, or the
                // highlight landing there while a page redraws) doesn't.
                onFocus = { if (open) onRest(item) },
                onClick = { onChoose(item) },
                modifier = Modifier.focusProperties { right = content }.then(if (item == shown) Modifier.focusRequester(focus) else Modifier),
            )
            // Search sits apart above the sections.
            if (item == Section.Search) Spacer(Modifier.height(10.dp))
        }
    }
}

@Composable
private fun RailItem(section: Section, selected: Boolean, open: Boolean, onFocus: () -> Unit, onClick: () -> Unit, modifier: Modifier) {
    var focused by remember { mutableStateOf(false) }
    Surface(
        onClick = onClick,
        modifier = modifier
            .fillMaxWidth()
            .height(48.dp)
            .onFocusChanged {
                focused = it.isFocused
                if (it.isFocused) onFocus()
            },
        shape = ClickableSurfaceDefaults.shape(RoundedCornerShape(10.dp)),
        colors = ClickableSurfaceDefaults.colors(
            containerColor = if (selected && !open) LumioColors.raised else Color.Transparent,
            contentColor = if (selected) LumioColors.accent else LumioColors.secondaryText,
            focusedContainerColor = LumioColors.accent,
            focusedContentColor = LumioColors.onAccent,
            pressedContainerColor = LumioColors.accent,
            pressedContentColor = LumioColors.onAccent,
        ),
        scale = ClickableSurfaceDefaults.scale(focusedScale = 1f),
    ) {
        Row(Modifier.fillMaxSize().padding(start = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(painterResource(section.icon), contentDescription = section.title, modifier = Modifier.size(24.dp))
            if (open) {
                Text(section.title, fontSize = 17.sp, fontWeight = if (selected || focused) FontWeight.SemiBold else FontWeight.Normal,
                    softWrap = false, maxLines = 1, modifier = Modifier.padding(start = 16.dp))
            }
        }
    }
}
