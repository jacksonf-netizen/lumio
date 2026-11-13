package com.jackson.lumio.ui.providers

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.jackson.lumio.core.CoreException
import com.jackson.lumio.core.GuideLinks
import com.jackson.lumio.core.LumioCore
import com.jackson.lumio.core.ProviderEditor
import com.jackson.lumio.core.ParsedLinks
import com.jackson.lumio.core.ProviderInfo
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.launch

data class ProvidersState(
    val providers: List<ProviderInfo> = emptyList(),
    /** False until the first read, so the empty state doesn't flash at launch. */
    val loaded: Boolean = false,
    /** What each refresh in progress is doing, by provider ID (live, from the core's events). */
    val syncing: Map<String, String> = emptyMap(),
    /** The step each refresh in progress is on (account, live, movies, series, matching, guide). */
    val steps: Map<String, String> = emptyMap(),
    /** Providers whose last refresh has finished (and been read back) since the app started. */
    val finished: Set<String> = emptySet(),
    val message: String? = null,
) {
    /** "Updating Provider A", "Updating 2 providers", or null. */
    val syncSummary: String?
        get() = when (syncing.size) {
            0 -> null
            1 -> "Updating ${providers.firstOrNull { it.id == syncing.keys.first() }?.name ?: "provider"}"
            else -> "Updating ${syncing.size} providers"
        }
}

/** What Settings → Providers shows. */
sealed interface ProviderScreen {
    data object List : ProviderScreen
    /** The form: a new provider, or changing one. */
    data object Form : ProviderScreen
    /** A new provider loading for the first time, step by step. */
    data class Setup(val providerId: String) : ProviderScreen
    /** A provider's extra guide links. */
    data class GuideLinks(val providerId: String) : ProviderScreen
}

/** The guide links page: what's saved, and the address being typed (kept while the page is away). */
class GuideLinksForm(val providerId: String) {
    var links by mutableStateOf<GuideLinks?>(null)
    var text by mutableStateOf("")
    /** Why the last Add didn't work. */
    var message by mutableStateOf<String?>(null)
    var busy by mutableStateOf(false)
}

/**
 * What's typed in the provider form. It lives in the view model, so Back, the sidebar or another
 * section never loses it: only Save or Discard ends it. Kept in memory only, never saved.
 */
class ProviderForm(
    /** Null for a new provider. */
    val providerId: String?,
    name: String,
) {
    var name by mutableStateOf(name)
    /** One field per server link: a TV keyboard has no key for a new line. */
    val links = mutableStateListOf("")
    var username by mutableStateOf("")
    var password by mutableStateOf("")
    /** A pasted M3U or stream link carried the login and it filled the fields. */
    var foundLogin by mutableStateOf(false)
    /** Why the last Save didn't work. */
    var message by mutableStateOf<String?>(null)
    var saving by mutableStateOf(false)
    /** Something was typed or changed since the form opened, so leaving asks first. */
    var changed by mutableStateOf(false)

    val servers: String get() = links.map { it.trim() }.filter { it.isNotEmpty() }.joinToString("\n")
}

/** Settings → Providers. Every action is a core request; the rules are the shared core's. */
@OptIn(FlowPreview::class)
class ProvidersViewModel : ViewModel() {
    var state by mutableStateOf(ProvidersState())
        private set
    var screen by mutableStateOf<ProviderScreen>(ProviderScreen.List)
        private set
    /** The form's contents, kept while it's away (see [ProviderForm]). */
    var form by mutableStateOf<ProviderForm?>(null)
        private set
    /**
     * Set when the pane changes by the remote's doing (Add, Save, Discard…): the new pane moves
     * the highlight into itself, then clears it. Not set when the pane only reappears (going back
     * to Settings), so browsing Settings' pages never has the form snatch the remote.
     */
    var takeFocus by mutableStateOf(false)
    /** The guide links page's contents. */
    var guide by mutableStateOf<GuideLinksForm?>(null)
        private set
    /** The provider whose row the list highlights when it comes back (the one edited or added). */
    var returnTo by mutableStateOf<String?>(null)
        private set

    init {
        reload()
        viewModelScope.launch {
            LumioCore.events.collect { event ->
                val id = event.provider
                if (event.type == "sync" && id != null) {
                    val syncing = state.syncing.toMutableMap()
                    val steps = state.steps.toMutableMap()
                    if (event.finished) {
                        syncing.remove(id)
                        steps.remove(id)
                        state = state.copy(syncing = syncing, steps = steps)
                        // Finished once the provider's counts and problems are read back, so the
                        // setup screen never shows the outcome with the figures from before.
                        load()
                        state = state.copy(finished = state.finished + id)
                        // The guide links page shows the guide's last problem.
                        if (guide?.providerId == id) readGuideLinks()
                    } else {
                        val stepChanged = event.step != state.steps[id]
                        event.label?.let { syncing[id] = it }
                        if (event.step != null) steps[id] = event.step else steps.remove(id)
                        state = state.copy(syncing = syncing, steps = steps, finished = state.finished - id)
                        // A step finished: its counts (channels, movies…) are read for the rows.
                        if (stepChanged) load()
                    }
                }
            }
        }
        viewModelScope.launch {
            LumioCore.events.filter { it.type == "providers" || (it.type == "sync" && it.finished) }
                .debounce(300)
                .collect { reload() }
        }
    }

    fun reload() {
        viewModelScope.launch { load() }
    }

    private suspend fun load() {
        try {
            state = state.copy(providers = LumioCore.providers(), loaded = true)
        } catch (error: CoreException) {
            state = state.copy(loaded = true, message = error.message)
        }
    }

    // MARK: The form

    /** Opens the form for a new provider, with what was typed last time if it was never saved. */
    fun startAdding() {
        returnTo = null
        if (form?.providerId != null) form = null
        if (form == null) form = ProviderForm(null, "")
        show(ProviderScreen.Form)
    }

    private fun show(next: ProviderScreen) {
        screen = next
        takeFocus = true
    }

    /** Opens the form for [provider], its links and username filled in (the password stays blank). */
    fun startEditing(provider: ProviderInfo) {
        val editing = ProviderForm(provider.id, provider.name)
        returnTo = provider.id
        form = editing
        show(ProviderScreen.Form)
        viewModelScope.launch {
            val saved = editor(provider.id) ?: return@launch
            if (form !== editing || editing.changed) return@launch
            editing.links.clear()
            editing.links.addAll(saved.servers.lines().filter { it.isNotBlank() }.ifEmpty { listOf("") })
            editing.username = saved.username
        }
    }

    /** Closes the form and forgets what was typed. */
    fun discardForm() {
        form = null
        show(ProviderScreen.List)
    }

    /**
     * Saves the form. A new provider then shows its first load step by step ([ProviderScreen.Setup]);
     * a changed one goes back to the list, where its row shows the refresh.
     */
    fun submit() {
        val current = form ?: return
        if (current.saving) return
        current.saving = true
        current.message = null
        viewModelScope.launch {
            val id = current.providerId
            if (id == null) {
                try {
                    val added = LumioCore.addProvider(current.name, current.servers, current.username, current.password)
                    load()
                    show(ProviderScreen.Setup(added))
                } catch (error: CoreException) {
                    current.message = error.message ?: "Something went wrong."
                }
            } else {
                current.message = save(id, current.name, current.servers, current.username, current.password)
                if (current.message == null) discardForm()
            }
            current.saving = false
        }
    }

    // MARK: Guide links

    /** Opens the guide links page for [providerId]; what was typed for another provider is dropped. */
    fun openGuideLinks(providerId: String) {
        if (guide?.providerId != providerId) guide = GuideLinksForm(providerId)
        returnTo = providerId
        show(ProviderScreen.GuideLinks(providerId))
        readGuideLinks()
    }

    /** Back from the page: the list highlights the provider again. */
    fun closeGuideLinks() {
        returnTo = guide?.providerId
        show(ProviderScreen.List)
    }

    private fun readGuideLinks() {
        val current = guide ?: return
        viewModelScope.launch {
            runCatching { LumioCore.guideLinks(current.providerId) }.getOrNull()?.let { current.links = it }
        }
    }

    /** Adds what's typed; the core refreshes the guide with it. A message says why it wasn't a link. */
    fun addGuideLink() {
        val current = guide ?: return
        val text = current.text.trim()
        if (text.isEmpty() || current.busy) return
        current.busy = true
        current.message = null
        viewModelScope.launch {
            try {
                current.links = LumioCore.addGuideLink(current.providerId, text)
                current.text = ""
            } catch (error: CoreException) {
                current.message = error.message ?: "Something went wrong."
            }
            current.busy = false
            reload()
        }
    }

    fun removeGuideLink(index: Int) {
        val current = guide ?: return
        viewModelScope.launch {
            try {
                current.links = LumioCore.removeGuideLink(current.providerId, index)
                current.message = null
            } catch (error: CoreException) {
                current.message = error.message ?: "Something went wrong."
            }
            reload()
        }
    }

    // MARK: Setup

    /**
     * Back from a new provider that couldn't sign in: it's removed (it never loaded anything) and
     * the form opens again as it was typed, saying what went wrong.
     */
    fun changeDetails(providerId: String, problem: String?) {
        viewModelScope.launch {
            attempt { LumioCore.removeProvider(providerId) }
            load()
            val kept = form?.takeIf { it.providerId == null } ?: ProviderForm(null, "")
            kept.message = problem
            form = kept
            show(ProviderScreen.Form)
        }
    }

    /**
     * Leaves the setup screen; the provider stays and carries on loading if it hasn't finished.
     * [stay] false when the app goes on to Live TV, so the list doesn't take the remote later.
     */
    fun finishSetup(stay: Boolean = true) {
        returnTo = (screen as? ProviderScreen.Setup)?.providerId
        form = null
        show(ProviderScreen.List)
        takeFocus = stay
    }

    /** Returns null on success, or a message for the editor. */
    suspend fun save(id: String, name: String, servers: String, username: String, password: String): String? = attempt {
        LumioCore.saveProvider(id, name, servers, username, password)
    }

    suspend fun editor(id: String): ProviderEditor? = runCatching { LumioCore.providerEditor(id) }.getOrNull()

    /** Null when the text isn't a list of links (Save explains why). */
    suspend fun parseLinks(text: String): ParsedLinks? = try {
        LumioCore.parseLinks(text)
    } catch (error: CoreException) {
        null
    }

    fun remove(id: String) = act { LumioCore.removeProvider(id) }

    fun setEnabled(id: String, enabled: Boolean) = act { LumioCore.setProviderEnabled(id, enabled) }

    fun refresh(id: String? = null) = act { LumioCore.refresh(id) }

    /** Moves a provider one place up (-1) or down (+1); the first has the highest priority. */
    fun move(id: String, by: Int) {
        val ids = state.providers.map { it.id }.toMutableList()
        val from = ids.indexOf(id)
        val to = from + by
        if (from < 0 || to !in ids.indices) return
        ids.add(to, ids.removeAt(from))
        act { LumioCore.reorderProviders(ids) }
    }

    fun dismissMessage() {
        state = state.copy(message = null)
    }

    private fun act(work: suspend () -> Unit) {
        viewModelScope.launch {
            attempt(work)?.let { state = state.copy(message = it) }
            reload()
        }
    }

    private suspend fun attempt(work: suspend () -> Unit): String? = try {
        work()
        null
    } catch (error: CoreException) {
        error.message ?: "Something went wrong."
    }
}
