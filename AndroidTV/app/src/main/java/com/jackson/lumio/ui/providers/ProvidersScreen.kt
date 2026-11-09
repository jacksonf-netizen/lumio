package com.jackson.lumio.ui.providers

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.tv.material3.Text
import com.jackson.lumio.core.ProviderInfo
import com.jackson.lumio.ui.LumioColors
import com.jackson.lumio.ui.common.ButtonStyle
import com.jackson.lumio.ui.common.LumioButton
import com.jackson.lumio.ui.common.MenuAction
import com.jackson.lumio.ui.common.RemoteTextField
import com.jackson.lumio.ui.settings.Picker
import com.jackson.lumio.ui.settings.SettingRow
import com.jackson.lumio.ui.settings.SettingsPane
import com.jackson.lumio.ui.settings.heading
import com.jackson.lumio.ui.settings.note
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.launch

/**
 * Settings → Providers: a row per provider (its state on the right), OK opens what can be done
 * with it. "Add provider" and Edit open the form in the same pane.
 */
@Composable
fun ProvidersPane(model: ProvidersViewModel, focus: FocusRequester, pick: (Picker) -> Unit) {
    // Null: the list. Otherwise the form, for a new provider (Adding) or an existing one.
    var editing by remember { mutableStateOf<Editing?>(null) }
    when (val current = editing) {
        null -> ProviderList(model, focus, pick, onAdd = { editing = Editing(null) }, onEdit = { editing = Editing(it) })
        else -> ProviderEditor(model, current.provider, onDone = { editing = null })
    }
}

private data class Editing(val provider: ProviderInfo?)

@Composable
private fun ProviderList(model: ProvidersViewModel, focus: FocusRequester, pick: (Picker) -> Unit, onAdd: () -> Unit, onEdit: (ProviderInfo) -> Unit) {
    val state = model.state
    SettingsPane("Providers", focus) {
        state.message?.let { message ->
            item { SettingRow(message, "OK", valueColor = LumioColors.error, onClick = model::dismissMessage) }
        }
        if (state.loaded && state.providers.isEmpty()) {
            note("Add your IPTV provider to start: its server link, and your username and password. Logins are stored encrypted on this TV only.")
        }
        item { SettingRow("Add provider", "", valueColor = LumioColors.accent, onClick = onAdd) }
        if (state.providers.isNotEmpty()) {
            heading("Your providers")
            items(state.providers, key = { it.id }) { provider ->
                val syncing = state.syncing[provider.id] ?: provider.syncing
                val (value, color) = when {
                    !provider.enabled -> "Off" to LumioColors.secondaryText
                    provider.unreachable -> "Can't connect" to LumioColors.error
                    syncing != null -> syncing to LumioColors.accent
                    provider.lastError != null -> "Problem" to LumioColors.warning
                    else -> "On" to LumioColors.accent
                }
                val counts = listOfNotNull(plural(provider.channels, "channel"), plural(provider.movies, "movie"), "${provider.series} series",
                    provider.lastRefreshAt?.let { "updated ${updated(it)}" })
                SettingRow(provider.name, value, counts.joinToString("  ·  "), valueColor = color) {
                    pick(options(model, provider, state.providers, onEdit, pick))
                }
            }
            item { SettingRow("Refresh all now", "") { model.refresh() } }
            note("Providers higher up are tried first when a channel is on more than one.")
        }
    }
}

/** What OK on a provider offers, with its details above. */
private fun options(
    model: ProvidersViewModel,
    provider: ProviderInfo,
    all: List<ProviderInfo>,
    onEdit: (ProviderInfo) -> Unit,
    pick: (Picker) -> Unit,
): Picker {
    val index = all.indexOfFirst { it.id == provider.id }
    val actions = buildList {
        add(MenuAction("Refresh now") { model.refresh(provider.id) })
        add(MenuAction("Edit") { onEdit(provider) })
        add(MenuAction(if (provider.enabled) "Switch off" else "Switch on") { model.setEnabled(provider.id, !provider.enabled) })
        if (index > 0) add(MenuAction("Move up") { model.move(provider.id, -1) })
        if (index in 0 until all.lastIndex) add(MenuAction("Move down") { model.move(provider.id, 1) })
        add(MenuAction("Remove…") {
            pick(Picker("Remove ${provider.name}?", listOf(
                MenuAction("Remove") { model.remove(provider.id) },
                MenuAction("Cancel") {},
            ), detail = "Its channels, films, guide and favourites go too. You can add it again later."))
        })
    }
    return Picker(provider.name, actions, detail = details(provider))
}

private fun details(provider: ProviderInfo): String = buildList {
    add("${plural(provider.channels, "channel")}  ·  ${plural(provider.movies, "movie")}  ·  ${provider.series} series  ·  ${plural(provider.programmes, "programme")}")
    add("Connections: ${provider.connectionsInUse} of ${provider.connectionLimit}")
    provider.expiresAt?.let { add("Expires ${DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date((it * 1000).toLong()))}") }
    provider.lastRefreshAt?.let { add("Updated ${updated(it)}") }
    for (link in provider.links) {
        add("${link.url}  ·  ${if (link.down) "down" else if (link.inUse) "in use" else "backup"}")
    }
    provider.lastError?.let { add(it) }
}.joinToString("\n")

/** "15 minutes ago", "yesterday". */
private fun updated(seconds: Double): String = android.text.format.DateUtils.getRelativeTimeSpanString(
    (seconds * 1000).toLong(), System.currentTimeMillis(), android.text.format.DateUtils.MINUTE_IN_MILLIS,
).toString().replaceFirstChar { it.lowercase() }

private fun plural(count: Int, one: String) = "$count $one${if (count == 1) "" else "s"}"

/** Add (provider = null) or edit a provider. An empty password keeps the saved one. Back cancels. */
@Composable
private fun ProviderEditor(model: ProvidersViewModel, provider: ProviderInfo?, onDone: () -> Unit) {
    var name by remember { mutableStateOf(provider?.name ?: "") }
    // One field per server link: a TV keyboard has no key for a new line.
    val links = remember { mutableStateListOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val first = remember { FocusRequester() }
    val saveButton = remember { FocusRequester() }

    BackHandler(onBack = onDone)
    LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
    LaunchedEffect(provider?.id) {
        if (provider != null) model.editor(provider.id)?.let { editor ->
            links.clear()
            links.addAll(editor.servers.lines().filter { it.isNotBlank() }.ifEmpty { listOf("") })
            username = editor.username
        }
    }

    SettingsPane(if (provider == null) "Add provider" else "Edit ${provider.name}", null, message) {
        item { Field("Name (optional)", name, modifier = Modifier.focusRequester(first)) { name = it } }
        items(links.size) { index ->
            Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                RemoteTextField(
                    if (index == 0) "Server link" else "Backup link $index",
                    links[index], keyboard = KeyboardType.Uri, modifier = Modifier.weight(1f),
                ) { links[index] = it }
                if (links.size > 1) LumioButton(onClick = { links.removeAt(index) }) { Text("Remove") }
            }
        }
        item {
            Box(Modifier.padding(start = 16.dp, top = 4.dp)) {
                LumioButton(onClick = { links.add("") }) { Text("Add a backup link") }
            }
        }
        item { Field("Username", username) { username = it } }
        item {
            Field(if (provider == null) "Password" else "Password (empty keeps the saved one)", password, secret = true) { password = it }
        }
        item {
            // Coming down from the last field lands on Save, not whichever button is nearest.
            Row(
                Modifier.padding(start = 16.dp, top = 16.dp).focusProperties { onEnter = { saveButton.requestFocus() } }.focusGroup(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                LumioButton(
                    modifier = Modifier.focusRequester(saveButton),
                    enabled = !saving,
                    style = ButtonStyle.Primary,
                    onClick = {
                        saving = true
                        val servers = links.map { it.trim() }.filter { it.isNotEmpty() }.joinToString("\n")
                        scope.launch {
                            message = if (provider == null) model.add(name, servers, username, password)
                            else model.save(provider.id, name, servers, username, password)
                            saving = false
                            if (message == null) onDone()
                        }
                    },
                ) { Text(if (saving) "Saving…" else "Save") }
                LumioButton(onClick = onDone) { Text("Cancel") }
            }
        }
    }
}

/** A labelled field in the form (see [RemoteTextField]). */
@Composable
private fun Field(
    label: String,
    value: String,
    secret: Boolean = false,
    keyboard: KeyboardType = KeyboardType.Text,
    modifier: Modifier = Modifier,
    onChange: (String) -> Unit,
) = Box(Modifier.padding(horizontal = 16.dp).fillMaxWidth()) {
    RemoteTextField(label, value, secret = secret, keyboard = keyboard, modifier = modifier.fillMaxWidth(), onChange = onChange)
}
