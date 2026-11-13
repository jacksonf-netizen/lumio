package com.jackson.lumio.ui.vod

import androidx.activity.compose.BackHandler
import com.jackson.lumio.ui.common.LumioListItem
import com.jackson.lumio.ui.common.LumioButton
import com.jackson.lumio.ui.common.ButtonStyle
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.Card
import androidx.tv.material3.CardDefaults
import androidx.tv.material3.Text
import com.jackson.lumio.core.ContinueItem
import com.jackson.lumio.core.Episode
import com.jackson.lumio.core.MovieInfo
import com.jackson.lumio.core.SeriesInfo
import com.jackson.lumio.core.VODCategory
import com.jackson.lumio.core.VODItem
import com.jackson.lumio.core.WatchProgress
import com.jackson.lumio.images.RemoteImage
import com.jackson.lumio.ui.LumioColors
import com.jackson.lumio.ui.Spinner
import com.jackson.lumio.ui.common.MenuAction
import com.jackson.lumio.ui.common.OptionsPanel
import com.jackson.lumio.ui.common.LumioTabs
import androidx.compose.runtime.saveable.rememberSaveable

/** Starts a movie or episode: kind (movie or episode), provider, id, position (null: the start), title, subtitle. */
typealias PlayVOD = (kind: String, provider: String, id: String, position: Double?, title: String, subtitle: String?) -> Unit

val PosterWidth = 124.dp
val PosterHeight = 186.dp

/** A list of choices over the page (Hold OK's options), with optional [detail] text under the title. */
data class Panel(val title: String, val actions: List<MenuAction>, val detail: String? = null)

/**
 * What a screen hosting movie and series pages can do: open a page over itself, play, and show a
 * panel of choices. Movies, Series and Search are each a home page in a [VODHost].
 */
class VODHostScope(
    val open: (VODPage) -> Unit,
    val play: PlayVOD,
    val showPanel: (Panel) -> Unit,
    /** The Movies (movie) or Series (series) model; shared with those sections. */
    val model: (String) -> VODViewModel,
) {
    fun openItem(item: VODItem) =
        open(if (item.kind == "movie") VODPage.Movie(item.provider, item.id) else VODPage.Series(item.provider, item.id))

    /** Hold OK on a poster. */
    fun itemOptions(item: VODItem) {
        showPanel(Panel(item.name, listOf(
            MenuAction(if (item.kind == "movie") "Show movie" else "Show series") { openItem(item) },
            MenuAction(if (item.favorite) "Remove from Favorites" else "Add to Favorites") {
                model(item.kind).setFavorite(item.kind, item.provider, item.id.toString(), !item.favorite)
            },
        )))
    }

    /** Hold OK on a category ("See all" or a category card): hide it (Settings → Content shows it again). */
    fun categoryOptions(kind: String, category: VODCategory) {
        showPanel(Panel(category.name, listOf(
            MenuAction("Open") { open(VODPage.Category(kind, category)) },
            MenuAction("Hide category") { model(kind).hideCategory(category) },
        ), detail = "Hidden categories leave Movies and Series. Settings → Content lists them, to show them again."))
    }

    /** OK on a Recently Watched card: resumes, or opens the page when there's nothing to resume. */
    fun openRecent(item: ContinueItem) {
        when {
            item.canResume -> play(item.kind, item.provider, item.id, item.position, item.title, item.subtitle)
            item.kind == "movie" -> item.id.toIntOrNull()?.let { open(VODPage.Movie(item.provider, it)) }
            else -> item.series?.let { open(VODPage.Series(item.provider, it)) }
        }
    }

    /** Hold OK on a Recently Watched card. */
    fun recentOptions(item: ContinueItem, kind: String) {
        val owner = model(kind)
        val actions = buildList {
            if (item.canResume) {
                add(MenuAction("Resume") { play(item.kind, item.provider, item.id, item.position, item.title, item.subtitle) })
                add(MenuAction("Play from the beginning") { play(item.kind, item.provider, item.id, null, item.title, item.subtitle) })
            } else {
                add(MenuAction("Play") { play(item.kind, item.provider, item.id, null, item.title, item.subtitle) })
            }
            add(MenuAction(if (item.kind == "movie") "Show movie" else "Show series") {
                if (item.kind == "movie") item.id.toIntOrNull()?.let { open(VODPage.Movie(item.provider, it)) }
                else item.series?.let { open(VODPage.Series(item.provider, it)) }
            })
            add(MenuAction("Remove from Recently Watched") { owner.removeRecent(item) })
            add(MenuAction("Clear Recently Watched…") {
                showPanel(Panel("Clear Recently Watched?", listOf(MenuAction("Clear") { owner.clearRecents() }, MenuAction("Cancel") {})))
            })
        }
        showPanel(Panel(item.title, actions))
    }
}

/**
 * On Demand: Movies and Series ([kinds], those not switched off in Settings) under tabs. Each home
 * shows Recently Watched, Recently Added and a shelf per category; a category, movie or series
 * opens over it.
 */
@Composable
fun OnDemandScreen(
    kinds: List<String>,
    onPlay: PlayVOD,
    playerShowing: Boolean,
    /** The provider being refreshed right now (its name), or null when none is. */
    refreshing: String? = null,
) {
    var chosen by rememberSaveable { mutableStateOf("movie") }
    val kind = if (chosen in kinds) chosen else kinds.first()
    VODHost(onPlay, playerShowing) {
        Home(model(kind), kind, refreshing, onOpen = ::openItem, onCategory = { open(VODPage.Category(kind, it)) },
            onCategoryOptions = { categoryOptions(kind, it) },
            onRecent = ::openRecent, onRecentOptions = { recentOptions(it, kind) }, onItemOptions = ::itemOptions,
            header = {
                LumioTabs(kinds.map { if (it == "movie") "Movies" else "Series" }, kinds.indexOf(kind), onSelect = { chosen = kinds[it] },
                    modifier = Modifier.padding(start = 32.dp, top = 28.dp, bottom = 4.dp))
            })
    }
}

/**
 * A home page ([home]) with movie, series and category pages opening over it. The page below stays
 * composed as it was, so Back returns to the same poster, row or result.
 */
@Composable
fun VODHost(onPlay: PlayVOD, playerShowing: Boolean, home: @Composable VODHostScope.() -> Unit) {
    val movies: VODViewModel = viewModel(key = "vod-movie") { VODViewModel("movie") }
    val series: VODViewModel = viewModel(key = "vod-series") { VODViewModel("series") }
    val model = { kind: String -> if (kind == "movie") movies else series }
    val stack = remember { mutableStateListOf<VODPage>() }
    val layerFocus = remember { mutableStateListOf(FocusRequester()) }
    var panel by remember { mutableStateOf<Panel?>(null) }
    var played by remember { mutableStateOf(false) }

    fun focusTop() {
        runCatching { layerFocus.last().requestFocus() }
    }

    fun close() {
        when (val page = stack.removeAt(stack.lastIndex)) {
            is VODPage.Movie -> movies.close(page)
            is VODPage.Series -> series.close(page)
            is VODPage.Category -> {}
        }
        layerFocus.removeAt(layerFocus.lastIndex)
    }

    val scope = remember {
        VODHostScope(
            open = { page ->
                when (page) {
                    is VODPage.Movie -> movies.openMovie(page.provider, page.id)
                    is VODPage.Series -> series.openSeries(page.provider, page.id)
                    is VODPage.Category -> {}
                }
                stack.add(page)
                layerFocus.add(FocusRequester())
            },
            play = { kind, provider, id, position, title, subtitle ->
                played = true
                onPlay(kind, provider, id, position, title, subtitle)
            },
            showPanel = { panel = it },
            model = model,
        )
    }

    BackHandler(enabled = stack.isNotEmpty() && panel == null && !playerShowing) {
        close()
    }
    // A page opened or closed: the remote goes to the page on top (where it last was on that page).
    var pages by remember { mutableStateOf(0) }
    LaunchedEffect(stack.size) {
        if (stack.size != pages) focusTop()
        pages = stack.size
    }
    // Closing the player (a movie, an episode, or a channel from Search) brings the remote back here.
    var sawPlayer by remember { mutableStateOf(false) }
    LaunchedEffect(playerShowing) {
        if (playerShowing) sawPlayer = true else if (sawPlayer || played) {
            sawPlayer = false
            played = false
            focusTop()
        }
    }
    var hadPanel by remember { mutableStateOf(false) }
    LaunchedEffect(panel == null) {
        if (panel != null) hadPanel = true else if (hadPanel) {
            hadPanel = false
            focusTop()
        }
    }

    Box(Modifier.fillMaxSize()) {
        Layer(covered = stack.isNotEmpty(), focus = layerFocus[0]) { scope.home() }
        stack.forEachIndexed { index, page ->
            key(page) {
                Layer(covered = index < stack.lastIndex, focus = layerFocus[index + 1]) {
                    when (page) {
                        is VODPage.Category -> CategoryGrid(model(page.kind), page.category, onOpen = scope::openItem,
                            onOptions = scope::itemOptions)
                        is VODPage.Movie -> MoviePage(movies, page, onPlay = scope.play)
                        is VODPage.Series -> SeriesPage(series, page, onPlay = scope.play, onOptions = { panel = it })
                    }
                }
            }
        }
        panel?.let { shown ->
            key(shown) {
                OptionsPanel(shown.title, shown.actions, onDismiss = { if (panel === shown) panel = null },
                    detail = shown.detail?.let { text -> { Text(text, color = LumioColors.secondaryText, fontSize = 15.sp, maxLines = 12) } })
            }
        }
    }
}

/**
 * One page. A covered page stays composed (so it keeps its scroll and where the remote was) but
 * isn't drawn and can't be focused; [focus] brings the remote back to it.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun Layer(covered: Boolean, focus: FocusRequester, content: @Composable () -> Unit) {
    Box(
        Modifier
            .fillMaxSize()
            .graphicsLayer { alpha = if (covered) 0f else 1f }
            .background(LumioColors.background)
            .focusRequester(focus)
            .focusRestorer()
            .focusProperties { if (covered) onEnter = { cancelFocusChange() } }
            .focusGroup(),
    ) {
        content()
    }
}

// MARK: Home

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun Home(
    model: VODViewModel,
    kind: String,
    refreshing: String?,
    onOpen: (VODItem) -> Unit,
    onCategory: (VODCategory) -> Unit,
    onCategoryOptions: (VODCategory) -> Unit,
    onRecent: (ContinueItem) -> Unit,
    onRecentOptions: (ContinueItem) -> Unit,
    onItemOptions: (VODItem) -> Unit,
    header: @Composable () -> Unit,
) {
    val home = model.home
    val title = if (kind == "movie") "Movies" else "Series"
    val empty = home != null && home.recentlyAdded.isEmpty() && home.shelves.isEmpty() && home.recentlyWatched.isEmpty()
    Column(Modifier.fillMaxSize()) {
    header()
    when {
        home == null && model.message != null -> Message(model.message!!, LumioColors.error)
        empty && refreshing != null -> Row(Modifier.padding(24.dp), verticalAlignment = Alignment.CenterVertically) {
            Spinner()
            Text("$title are loading from $refreshing…", color = LumioColors.secondaryText, fontSize = 18.sp, modifier = Modifier.padding(start = 12.dp))
        }
        empty -> Message("No ${title.lowercase()} yet. They appear here once your provider has loaded.", LumioColors.secondaryText)
        home == null -> Message("Loading…", LumioColors.secondaryText)
        else -> LazyColumn(
            Modifier.fillMaxSize().focusRestorer(),
            contentPadding = PaddingValues(top = 20.dp, bottom = 48.dp),
            verticalArrangement = Arrangement.spacedBy(26.dp),
        ) {
            if (home.recentlyWatched.isNotEmpty()) {
                item(key = "recent") {
                    Shelf("Recently Watched") {
                        items(home.recentlyWatched, key = { "${it.kind}|${it.provider}|${it.id}" }) { item ->
                            ContinueCard(item, onClick = { onRecent(item) }, onLongClick = { onRecentOptions(item) })
                        }
                    }
                }
            }
            if (home.recentlyAdded.isNotEmpty()) {
                item(key = "added") {
                    Shelf("Recently Added") {
                        items(home.recentlyAdded, key = { "${it.provider}|${it.id}" }) { item ->
                            PosterCard(item, onClick = { onOpen(item) }, onLongClick = { onItemOptions(item) })
                        }
                    }
                }
            }
            items(home.shelves, key = { "shelf|${it.category.provider}|${it.category.id}" }) { shelf ->
                Shelf(shelf.category.name) {
                    items(shelf.items, key = { "${it.provider}|${it.id}" }) { item ->
                        PosterCard(item, onClick = { onOpen(item) }, onLongClick = { onItemOptions(item) })
                    }
                    item(key = "all") { MoreCard("See all", onLongClick = { onCategoryOptions(shelf.category) }) { onCategory(shelf.category) } }
                }
            }
            if (home.categories.size > home.shelves.size) {
                item(key = "categories") {
                    Shelf("All categories") {
                        items(home.categories, key = { "${it.provider}|${it.id}" }) { category ->
                            CategoryCard(category.name, onLongClick = { onCategoryOptions(category) }) { onCategory(category) }
                        }
                    }
                }
            }
        }
    }
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun Shelf(title: String, content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    Column {
        Text(title, fontSize = 19.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(start = 32.dp, bottom = 10.dp))
        LazyRow(
            Modifier.fillMaxWidth().focusRestorer(),
            contentPadding = PaddingValues(horizontal = 32.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            content = content,
        )
    }
}

@Composable
private fun Message(text: String, color: Color) {
    Text(text, color = color, fontSize = 18.sp, modifier = Modifier.padding(32.dp))
}

// MARK: Cards

@Composable
fun PosterCard(item: VODItem, onClick: () -> Unit, onLongClick: () -> Unit) {
    Column(Modifier.width(PosterWidth)) {
        Card(onClick = onClick, onLongClick = onLongClick, scale = CardDefaults.scale(focusedScale = 1.05f), modifier = Modifier.size(PosterWidth, PosterHeight)) {
            Box(Modifier.fillMaxSize().background(LumioColors.raised)) {
                if (item.poster == null) {
                    Text(item.name, color = LumioColors.secondaryText, fontSize = 14.sp, maxLines = 4,
                        modifier = Modifier.align(Alignment.Center).padding(10.dp))
                }
                RemoteImage(item.poster, PosterWidth, PosterHeight)
                if (item.favorite) {
                    Text("★", color = LumioColors.accent, fontSize = 16.sp,
                        modifier = Modifier.align(Alignment.TopEnd).padding(6.dp)
                            .background(Color(0x99000000), RoundedCornerShape(4.dp)).padding(horizontal = 4.dp))
                }
                item.progress?.takeIf { it > 0 }?.let { ProgressBar(it.toFloat(), Modifier.align(Alignment.BottomCenter)) }
            }
        }
        Text(item.name, fontSize = 13.sp, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 14.dp))
    }
}

@Composable
private fun ContinueCard(item: ContinueItem, onClick: () -> Unit, onLongClick: () -> Unit) {
    val width = 230.dp
    Column(Modifier.width(width)) {
        Card(onClick = onClick, onLongClick = onLongClick, scale = CardDefaults.scale(focusedScale = 1.05f), modifier = Modifier.size(width, 130.dp)) {
            Box(Modifier.fillMaxSize().background(LumioColors.raised)) {
                RemoteImage(item.image, width, 130.dp)
                val fraction = when {
                    item.watched -> 1f
                    item.duration != null && item.duration > 0 -> (item.position / item.duration).toFloat()
                    else -> 0f
                }
                if (fraction > 0) ProgressBar(fraction, Modifier.align(Alignment.BottomCenter), done = item.watched)
            }
        }
        Text(item.title, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 14.dp))
        val detail = listOfNotNull(item.subtitle, if (item.canResume) "${clock(item.position)} watched" else if (item.watched) "Watched" else null)
        Text(detail.joinToString("  ·  "), color = LumioColors.secondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun MoreCard(text: String, onLongClick: () -> Unit, onClick: () -> Unit) {
    Card(onClick = onClick, onLongClick = onLongClick, scale = CardDefaults.scale(focusedScale = 1.05f), modifier = Modifier.size(PosterWidth, PosterHeight)) {
        Box(Modifier.fillMaxSize().background(LumioColors.surface), contentAlignment = Alignment.Center) {
            Text(text, fontSize = 16.sp, color = LumioColors.text)
        }
    }
}

@Composable
private fun CategoryCard(name: String, onLongClick: () -> Unit, onClick: () -> Unit) {
    Card(onClick = onClick, onLongClick = onLongClick, scale = CardDefaults.scale(focusedScale = 1.05f), modifier = Modifier.size(200.dp, 64.dp)) {
        Box(Modifier.fillMaxSize().background(LumioColors.surface).padding(horizontal = 14.dp), contentAlignment = Alignment.CenterStart) {
            Text(name, fontSize = 15.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun ProgressBar(fraction: Float, modifier: Modifier = Modifier, done: Boolean = false) {
    Box(modifier.fillMaxWidth().height(4.dp).background(Color(0x66000000))) {
        Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).fillMaxHeight().background(if (done) LumioColors.good else LumioColors.accent))
    }
}

// MARK: Category

@Composable
private fun CategoryGrid(model: VODViewModel, category: VODCategory, onOpen: (VODItem) -> Unit, onOptions: (VODItem) -> Unit) {
    val page = model.categories[model.categoryKey(category)]
    val grid = rememberLazyGridState()
    LaunchedEffect(category) { if (page == null) model.loadMore(category) }
    // Loads the next page as the last rows come on screen.
    LaunchedEffect(grid) {
        snapshotFlow { grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }.collect { last ->
            val loadedCount = model.categories[model.categoryKey(category)]?.items?.size ?: 0
            if (loadedCount > 0 && last >= loadedCount - 12) model.loadMore(category)
        }
    }
    Column(Modifier.fillMaxSize()) {
        Text(category.name, fontSize = 26.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 32.dp, top = 28.dp, bottom = 12.dp))
        val items = page?.items.orEmpty()
        if (items.isEmpty()) {
            Message(if (page?.loading != false) "Loading…" else "Nothing in this category.", LumioColors.secondaryText)
        } else {
            LazyVerticalGrid(
                columns = GridCells.Adaptive(PosterWidth + 16.dp),
                state = grid,
                contentPadding = PaddingValues(start = 32.dp, end = 32.dp, top = 6.dp, bottom = 48.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                items(items, key = { "${it.provider}|${it.id}" }) { item ->
                    PosterCard(item, onClick = { onOpen(item) }, onLongClick = { onOptions(item) })
                }
            }
        }
    }
}

// MARK: Movie

@Composable
private fun MoviePage(model: VODViewModel, page: VODPage.Movie, onPlay: PlayVOD) {
    val key = model.key(page.provider, page.id)
    val movie = model.movies[key]
    val first = remember { FocusRequester() }
    LaunchedEffect(movie != null) { if (movie != null) runCatching { first.requestFocus() } }
    if (movie == null) {
        Message("Loading…", LumioColors.secondaryText)
        return
    }
    Row(Modifier.fillMaxSize().padding(start = 32.dp, end = 32.dp, top = 36.dp), horizontalArrangement = Arrangement.spacedBy(28.dp)) {
        Box(Modifier.size(200.dp, 300.dp).clip(RoundedCornerShape(8.dp)).background(LumioColors.raised)) {
            RemoteImage(movie.poster, 200.dp, 300.dp)
        }
        Column(Modifier.weight(1f)) {
            Text(movie.name, fontSize = 30.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            val facts = listOfNotNull(movie.year?.toString(), movie.duration?.let(::duration), movie.genre,
                movie.rating?.let { "★ %.1f".format(it) }, movie.providerName.ifEmpty { null })
            Text(facts.joinToString("  ·  "), color = LumioColors.secondaryText, fontSize = 15.sp, modifier = Modifier.padding(top = 6.dp))
            val progress = movie.progress
            if (progress != null && progress.canResume) ResumeBar(progress)
            FlowRow(Modifier.padding(top = 18.dp), horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)) {
                val resume = progress?.canResume == true
                LumioButton(style = ButtonStyle.Primary, onClick = { onPlay("movie", movie.provider, movie.id.toString(), if (resume) progress?.position else null, movie.name, null) },
                    modifier = Modifier.focusRequester(first)) {
                    Text(if (resume) "Resume from ${clock(progress!!.position)}" else "Play")
                }
                if (resume) LumioButton(onClick = { onPlay("movie", movie.provider, movie.id.toString(), null, movie.name, null) }) { Text("Start over") }
                LumioButton(onClick = { model.setFavorite("movie", movie.provider, movie.id.toString(), !movie.favorite) }) {
                    Text(if (movie.favorite) "★ Favorite" else "Favorite")
                }
                LumioButton(onClick = { model.setWatched("movie", movie.provider, movie.id.toString(), progress?.watched != true) }) {
                    Text(if (progress?.watched == true) "✓ Watched" else "Mark watched")
                }
            }
            movie.plot?.let {
                Text(it, color = LumioColors.secondaryText, fontSize = 16.sp, maxLines = 6, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 20.dp))
            }
            movie.director?.let { Labeled("Director", it) }
            movie.cast?.let { Labeled("Cast", it) }
            model.detailErrors[key]?.let { Text(it, color = LumioColors.warning, fontSize = 13.sp, modifier = Modifier.padding(top = 14.dp)) }
        }
    }
}

@Composable
private fun ResumeBar(progress: WatchProgress) {
    val total = progress.duration?.takeIf { it > 0 } ?: return
    Box(Modifier.padding(top = 12.dp).width(320.dp).height(4.dp).clip(RoundedCornerShape(2.dp)).background(LumioColors.raised)) {
        Box(Modifier.fillMaxWidth((progress.position / total).toFloat().coerceIn(0f, 1f)).fillMaxHeight().background(LumioColors.accent))
    }
}

@Composable
private fun Labeled(label: String, value: String) {
    Row(Modifier.padding(top = 8.dp)) {
        Text("$label  ", color = LumioColors.secondaryText, fontSize = 14.sp)
        Text(value, fontSize = 14.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

// MARK: Series

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun SeriesPage(model: VODViewModel, page: VODPage.Series, onPlay: PlayVOD, onOptions: (Panel) -> Unit) {
    val key = model.key(page.provider, page.id)
    val series = model.series[key]
    val first = remember { FocusRequester() }
    var season by remember { mutableStateOf<Int?>(null) }
    val next = series?.episodes?.firstOrNull { it.id == series.next }
    // The episodes often arrive just after the page opens: Play takes the remote once it's there.
    LaunchedEffect(series != null, next != null) { if (series != null) runCatching { first.requestFocus() } }
    if (series == null) {
        Message("Loading…", LumioColors.secondaryText)
        return
    }
    val shownSeason = season ?: next?.season ?: series.seasons.firstOrNull()?.number
    fun playEpisode(episode: Episode, fromStart: Boolean = false) {
        val resume = !fromStart && episode.progress?.canResume == true
        onPlay("episode", series.provider, episode.id, if (resume) episode.progress?.position else null, series.name,
            "S${episode.season} E${episode.number} · ${episode.title}")
    }
    LazyColumn(Modifier.fillMaxSize().focusRestorer(), contentPadding = PaddingValues(start = 32.dp, end = 32.dp, top = 36.dp, bottom = 48.dp)) {
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                Box(Modifier.size(150.dp, 225.dp).clip(RoundedCornerShape(8.dp)).background(LumioColors.raised)) {
                    RemoteImage(series.cover, 150.dp, 225.dp)
                }
                Column(Modifier.weight(1f)) {
                    Text(series.name, fontSize = 30.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    val seasons = series.seasons.size
                    val facts = listOfNotNull(series.year?.toString(), "$seasons season${if (seasons == 1) "" else "s"}",
                        series.rating?.let { "★ %.1f".format(it) }, series.providerName.ifEmpty { null })
                    Text(facts.joinToString("  ·  "), color = LumioColors.secondaryText, fontSize = 15.sp, modifier = Modifier.padding(top = 6.dp))
                    Row(Modifier.padding(top = 18.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        if (next != null) {
                            val code = "S${next.season} E${next.number}"
                            LumioButton(style = ButtonStyle.Primary, onClick = { playEpisode(next) }, modifier = Modifier.focusRequester(first)) {
                                Text(if (next.progress?.canResume == true) "Resume $code" else "Play $code")
                            }
                        }
                        LumioButton(onClick = { model.setFavorite("series", series.provider, series.id.toString(), !series.favorite) },
                            modifier = if (next == null) Modifier.focusRequester(first) else Modifier) {
                            Text(if (series.favorite) "★ Favorite" else "Favorite")
                        }
                    }
                    series.plot?.let {
                        Text(it, color = LumioColors.secondaryText, fontSize = 15.sp, maxLines = 4, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.padding(top = 16.dp))
                    }
                    model.detailErrors[key]?.let { Text(it, color = LumioColors.warning, fontSize = 13.sp, modifier = Modifier.padding(top = 10.dp)) }
                }
            }
        }
        if (series.seasons.size > 1) {
            item {
                // Moving onto a season shows its episodes.
                LazyRow(Modifier.padding(top = 24.dp).focusRestorer(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(series.seasons, key = { it.number }) { item ->
                        LumioListItem(
                            selected = item.number == shownSeason,
                            onClick = { season = item.number },
                            headlineContent = { Text(item.name, maxLines = 1) },
                            modifier = Modifier.width(170.dp).onFocusChanged { if (it.isFocused) season = item.number },
                        )
                    }
                }
            }
        }
        if (series.episodes.isEmpty()) {
            item { Message(if (model.detailErrors[key] == null) "Loading episodes…" else "No episodes listed.", LumioColors.secondaryText) }
        }
        items(series.episodes.filter { it.season == shownSeason }, key = { it.id }) { episode ->
            EpisodeRow(episode, onClick = { playEpisode(episode) }, onLongClick = {
                val watched = episode.progress?.watched == true
                onOptions(Panel("E${episode.number} · ${episode.title}", buildList {
                    if (episode.progress?.canResume == true) {
                        add(MenuAction("Resume from ${clock(episode.progress.position)}") { playEpisode(episode) })
                        add(MenuAction("Play from the beginning") { playEpisode(episode, fromStart = true) })
                    } else {
                        add(MenuAction("Play") { playEpisode(episode) })
                    }
                    add(MenuAction(if (watched) "Mark unwatched" else "Mark watched") {
                        model.setWatched("episode", series.provider, episode.id, !watched)
                    })
                }))
            })
        }
    }
}

@Composable
private fun EpisodeRow(episode: Episode, onClick: () -> Unit, onLongClick: () -> Unit) {
    LumioListItem(
        selected = false,
        onClick = onClick,
        onLongClick = onLongClick,
        leadingContent = {
            Box(Modifier.size(144.dp, 81.dp).clip(RoundedCornerShape(6.dp)).background(LumioColors.raised)) {
                RemoteImage(episode.image, 144.dp, 81.dp)
                val progress = episode.progress
                val fraction = when {
                    progress == null -> 0f
                    progress.watched -> 1f
                    progress.duration != null && progress.duration > 0 -> (progress.position / progress.duration).toFloat()
                    else -> 0f
                }
                if (fraction > 0) ProgressBar(fraction, Modifier.align(Alignment.BottomCenter), done = progress?.watched == true)
            }
        },
        headlineContent = { Text("${episode.number}. ${episode.title}", fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            Column {
                val facts = listOfNotNull(episode.duration?.let(::duration),
                    episode.progress?.let { if (it.watched) "Watched" else if (it.canResume) "${clock(it.position)} watched" else null })
                if (facts.isNotEmpty()) Text(facts.joinToString("  ·  "), color = LumioColors.secondaryText, fontSize = 13.sp)
                episode.plot?.let { Text(it, color = LumioColors.secondaryText, fontSize = 13.sp, maxLines = 2, overflow = TextOverflow.Ellipsis) }
            }
        },
        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
    )
}

// MARK: Formatting

/** "1 h 56 min" from seconds. */
fun duration(seconds: Int): String {
    val minutes = seconds / 60
    return when {
        minutes < 60 -> "$minutes min"
        minutes % 60 == 0 -> "${minutes / 60} h"
        else -> "${minutes / 60} h ${minutes % 60} min"
    }
}

/** "30:20" or "1:02:03" from seconds. */
fun clock(seconds: Double): String {
    val total = seconds.toLong().coerceAtLeast(0)
    val h = total / 3600
    val m = total % 3600 / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}
