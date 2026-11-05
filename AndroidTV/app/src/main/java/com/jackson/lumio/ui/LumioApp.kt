package com.jackson.lumio.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.ListItem
import androidx.tv.material3.ListItemDefaults
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.Surface
import androidx.tv.material3.SurfaceDefaults
import androidx.tv.material3.Text
import com.jackson.lumio.ui.guide.GuideScope
import com.jackson.lumio.ui.guide.GuideScreen
import com.jackson.lumio.ui.live.LiveTvScreen
import com.jackson.lumio.ui.search.SearchScreen
import com.jackson.lumio.ui.vod.VODScreen
import com.jackson.lumio.ui.multiview.MultiviewScreen
import com.jackson.lumio.ui.multiview.MultiviewViewModel
import com.jackson.lumio.ui.player.PlayerScreen
import com.jackson.lumio.ui.player.PlayerViewModel
import com.jackson.lumio.ui.settings.SettingsScreen
import com.jackson.lumio.ui.settings.SettingsViewModel
import com.jackson.lumio.ui.providers.ProvidersViewModel

/** The sections in the sidebar, close to the Mac's order. */
enum class Section(val title: String, val key: String?) {
    Live("Live TV", "liveTV"),
    Guide("Guide", "guide"),
    Movies("Movies", "movies"),
    Series("Series", "series"),
    Favorites("Favorites", "favorites"),
    Recents("Recents", "recents"),
    Search("Search", "search"),
    /** Always shown. */
    Settings("Settings", null),
}

/** The whole app: a sidebar on the left (moved through with the remote) and the chosen section. */
@Composable
fun LumioApp() {
    val providers: ProvidersViewModel = viewModel()
    val player: PlayerViewModel = viewModel()
    val multiview: MultiviewViewModel = viewModel()
    val settings: SettingsViewModel = viewModel()
    // Sections switched off in Settings → General leave the sidebar.
    val hidden = settings.settings?.hiddenSidebarItems.orEmpty()
    val sections = Section.entries.filter { it.key == null || it.key !in hidden }
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
    // Back from a screen's content returns to the sidebar; Back on the sidebar leaves the app.
    val sidebarFocus = remember { FocusRequester() }
    var sidebarFocused by remember { mutableStateOf(false) }
    // Screens return the highlight to where it was when the player or multiview closes.
    val overlay = player.showing || multiview.showing
    BackHandler(enabled = !sidebarFocused && !overlay) { runCatching { sidebarFocus.requestFocus() } }

    // A Surface gives everything inside the theme's text colour.
    Surface(colors = SurfaceDefaults.colors(containerColor = LumioColors.background, contentColor = LumioColors.text)) {
    Row(Modifier.fillMaxSize()) {
        Column(
            Modifier
                .width(220.dp)
                .fillMaxHeight()
                .background(LumioColors.surface)
                .onFocusChanged { sidebarFocused = it.hasFocus }
                .padding(vertical = 32.dp, horizontal = 12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                "Lumio",
                style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.SemiBold),
                modifier = Modifier.padding(start = 12.dp, bottom = 24.dp),
            )
            for (item in sections) {
                ListItem(
                    selected = item == shown,
                    onClick = { section = item },
                    headlineContent = { Text(item.title, fontSize = 18.sp) },
                    colors = ListItemDefaults.colors(selectedContainerColor = LumioColors.raised),
                    modifier = Modifier.fillMaxWidth().then(if (item == shown) Modifier.focusRequester(sidebarFocus) else Modifier),
                )
            }
            Box(Modifier.weight(1f))
            state.syncSummary?.let {
                Text(it, color = LumioColors.secondaryText, fontSize = 13.sp, modifier = Modifier.padding(12.dp))
            }
        }
        Box(Modifier.weight(1f).fillMaxHeight()) {
            val play = { channel: String, group: String -> player.watch(channel, group) }
            val playing = player.state?.channel?.id
            val toSidebar = { runCatching { sidebarFocus.requestFocus() }; Unit }
            when (shown) {
                Section.Live -> LiveTvScreen(onPlay = play, playerShowing = overlay)
                Section.Guide -> GuideScreen(GuideScope.All, play, overlay, playing)
                Section.Movies, Section.Series -> {
                    val kind = if (shown == Section.Movies) "movie" else "series"
                    // One screen per kind, each keeping its own pages.
                    androidx.compose.runtime.key(kind) {
                        VODScreen(kind, onPlay = { k, provider, id, position, title, subtitle ->
                            player.playVOD(k, provider, id, position, title, subtitle)
                        }, playerShowing = overlay)
                    }
                }
                Section.Search -> SearchScreen(onWatch = play, onPlay = { k, provider, id, position, title, subtitle ->
                    player.playVOD(k, provider, id, position, title, subtitle)
                }, playerShowing = overlay)
                Section.Favorites -> GuideScreen(GuideScope.Favorites, play, overlay, playing, toSidebar)
                Section.Recents -> GuideScreen(GuideScope.Recents, play, overlay, playing, toSidebar)
                Section.Settings -> SettingsScreen(providers, settings)
            }
        }
    }
    if (player.showing) {
        PlayerScreen(player, onMultiview = if (multiview.available) ({
            val channel = player.state?.channel?.id
            val group = player.group
            player.dismiss()
            multiview.start(channel, group)
        }) else null)
    }
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
