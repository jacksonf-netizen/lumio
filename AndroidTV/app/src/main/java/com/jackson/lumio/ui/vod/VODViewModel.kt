package com.jackson.lumio.ui.vod

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.jackson.lumio.core.ContinueItem
import com.jackson.lumio.core.CoreException
import com.jackson.lumio.core.LumioCore
import com.jackson.lumio.core.MovieInfo
import com.jackson.lumio.core.SeriesInfo
import com.jackson.lumio.core.VODCategory
import com.jackson.lumio.core.VODHome
import com.jackson.lumio.core.VODItem
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch

/** A page shown over the Movies or Series home. */
sealed interface VODPage {
    data class Category(val category: VODCategory) : VODPage
    data class Movie(val provider: String, val id: Int) : VODPage
    data class Series(val provider: String, val id: Int) : VODPage
}

/** One page of a category, and whether there's more to load. */
data class CategoryPage(val items: List<VODItem> = emptyList(), val loading: Boolean = false, val complete: Boolean = false)

/**
 * Movies or Series ([kind] movie or series): the home shelves, category pages loaded a page at a
 * time, and the details pages open. Every rule is the core's; progress and Recently Watched come
 * back as `vod` events and the open pages re-read.
 */
@OptIn(FlowPreview::class)
class VODViewModel(val kind: String) : ViewModel() {
    var home by mutableStateOf<VODHome?>(null)
        private set
    var loaded by mutableStateOf(false)
        private set
    var message by mutableStateOf<String?>(null)
        private set
    val categories = mutableStateMapOf<String, CategoryPage>()
    val movies = mutableStateMapOf<String, MovieInfo>()
    val series = mutableStateMapOf<String, SeriesInfo>()
    /** Details the provider couldn't send, by page key. */
    val detailErrors = mutableStateMapOf<String, String>()

    private var homeJob: Job? = null

    init {
        reloadHome()
        viewModelScope.launch {
            LumioCore.events.filter { it.type == "vod" }.debounce(300).collect {
                reloadHome()
                for (key in movies.keys.toList()) refreshMovie(key)
                for (key in series.keys.toList()) refreshSeries(key)
            }
        }
        viewModelScope.launch {
            // A finished refresh can bring new titles.
            LumioCore.events.filter { it.type == "sync" && it.finished }.debounce(1000).collect {
                reloadHome()
                categories.clear()
            }
        }
    }

    fun reloadHome() {
        homeJob?.cancel()
        homeJob = viewModelScope.launch {
            try {
                home = LumioCore.vodHome(kind)
                message = null
            } catch (error: CoreException) {
                message = error.message
            }
            loaded = true
        }
    }

    // MARK: Categories

    fun categoryKey(category: VODCategory) = "${category.provider}|${category.id}"

    /** Loads the next page of [category] (the first when nothing has loaded). */
    fun loadMore(category: VODCategory) {
        val key = categoryKey(category)
        val page = categories[key] ?: CategoryPage()
        if (page.loading || page.complete) return
        categories[key] = page.copy(loading = true)
        viewModelScope.launch {
            val more = runCatching { LumioCore.vodCategory(kind, category.provider, category.id, page.items.size, PAGE) }.getOrNull()
            categories[key] = if (more == null) page.copy(loading = false)
            else CategoryPage(page.items + more, loading = false, complete = more.size < PAGE)
        }
    }

    // MARK: Details

    fun key(provider: String, id: Int) = "$provider|$id"

    /** Shows what the catalog has at once, then the provider's full details. */
    fun openMovie(provider: String, id: Int) {
        val key = key(provider, id)
        viewModelScope.launch {
            runCatching { LumioCore.movie(provider, id) }.getOrNull()?.let { movies[key] = it }
            try {
                val full = LumioCore.movie(provider, id, fetch = true)
                movies[key] = full
                full.detailsError?.let { detailErrors[key] = "Couldn't load full details: $it" } ?: detailErrors.remove(key)
            } catch (error: CoreException) {
                detailErrors[key] = error.message ?: ""
            }
        }
    }

    /** Shows the cached seasons at once, then fetches them again from the provider. */
    fun openSeries(provider: String, id: Int) {
        val key = key(provider, id)
        viewModelScope.launch {
            runCatching { LumioCore.series(provider, id) }.getOrNull()?.let { series[key] = it }
            try {
                val full = LumioCore.series(provider, id, fetch = true)
                series[key] = full
                full.detailsError?.let { detailErrors[key] = "Couldn't refresh episodes: $it" } ?: detailErrors.remove(key)
            } catch (error: CoreException) {
                detailErrors[key] = error.message ?: ""
            }
        }
    }

    fun close(page: VODPage) {
        when (page) {
            is VODPage.Movie -> movies.remove(key(page.provider, page.id))
            is VODPage.Series -> series.remove(key(page.provider, page.id))
            is VODPage.Category -> {}
        }
    }

    private fun refreshMovie(key: String) {
        val (provider, id) = key.split("|").let { it[0] to it[1].toInt() }
        viewModelScope.launch {
            runCatching { LumioCore.movie(provider, id) }.getOrNull()?.let { fresh ->
                // Keep the provider's details; take the new progress and favorite.
                movies[key] = movies[key]?.copy(progress = fresh.progress, favorite = fresh.favorite) ?: fresh
            }
        }
    }

    private fun refreshSeries(key: String) {
        val (provider, id) = key.split("|").let { it[0] to it[1].toInt() }
        viewModelScope.launch {
            runCatching { LumioCore.series(provider, id) }.getOrNull()?.let { series[key] = it }
        }
    }

    // MARK: Library

    fun setFavorite(kind: String, provider: String, id: String, favorite: Boolean) = act {
        LumioCore.setVODFavorite(kind, provider, id, favorite)
        val key = "$provider|$id"
        movies[key]?.let { movies[key] = it.copy(favorite = favorite) }
        series[key]?.let { series[key] = it.copy(favorite = favorite) }
        reloadHome()
    }

    fun setWatched(kind: String, provider: String, id: String, watched: Boolean) = act { LumioCore.setWatched(kind, provider, id, watched) }

    fun removeRecent(item: ContinueItem) = act {
        if (item.kind == "movie") LumioCore.removeVODRecent("movie", item.provider, item.id)
        else item.series?.let { LumioCore.removeVODRecent("series", item.provider, it.toString()) }
    }

    fun clearRecents() = act { LumioCore.clearVODRecents(kind) }

    private fun act(work: suspend () -> Unit) {
        viewModelScope.launch {
            try {
                work()
            } catch (error: CoreException) {
                message = error.message
            }
        }
    }

    companion object {
        const val PAGE = 120
    }
}
