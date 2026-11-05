package com.jackson.lumio.ui.providers

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.jackson.lumio.core.CoreException
import com.jackson.lumio.core.LumioCore
import com.jackson.lumio.core.ProviderEditor
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

/** Settings → Providers. Every action is a core request; the rules are the shared core's. */
@OptIn(FlowPreview::class)
class ProvidersViewModel : ViewModel() {
    var state by mutableStateOf(ProvidersState())
        private set

    init {
        reload()
        viewModelScope.launch {
            LumioCore.events.collect { event ->
                if (event.type == "sync" && event.provider != null) {
                    val syncing = state.syncing.toMutableMap()
                    if (event.finished) syncing.remove(event.provider) else event.label?.let { syncing[event.provider] = it }
                    state = state.copy(syncing = syncing)
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
        viewModelScope.launch {
            try {
                state = state.copy(providers = LumioCore.providers(), loaded = true)
            } catch (error: CoreException) {
                state = state.copy(loaded = true, message = error.message)
            }
        }
    }

    /** Returns null on success, or a message for the editor. */
    suspend fun add(name: String, servers: String, username: String, password: String): String? = attempt {
        LumioCore.addProvider(name, servers, username, password)
    }

    suspend fun save(id: String, name: String, servers: String, username: String, password: String): String? = attempt {
        LumioCore.saveProvider(id, name, servers, username, password)
    }

    suspend fun editor(id: String): ProviderEditor? = runCatching { LumioCore.providerEditor(id) }.getOrNull()

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
