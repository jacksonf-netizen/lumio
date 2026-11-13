package com.jackson.lumio.ui.providers

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.key
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Text
import com.jackson.lumio.core.ProviderInfo
import com.jackson.lumio.ui.LumioColors
import com.jackson.lumio.ui.common.ButtonStyle
import com.jackson.lumio.ui.common.LumioButton
import com.jackson.lumio.ui.common.MenuAction
import com.jackson.lumio.ui.common.Spinner
import com.jackson.lumio.ui.common.RemoteTextField
import com.jackson.lumio.ui.settings.Picker
import com.jackson.lumio.ui.settings.SettingRow
import com.jackson.lumio.ui.settings.SettingsPane
import com.jackson.lumio.ui.settings.heading
import com.jackson.lumio.ui.settings.note
import java.text.DateFormat
import java.text.NumberFormat
import java.util.Date
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Settings → Providers: a row per provider (its state on the right), OK opens what can be done
 * with it. "Add provider" and Edit open the form in the same pane; saving a new provider shows it
 * loading step by step. Which of these shows, and what's typed in the form, live in the view model,
 * so leaving and coming back finds them as they were.
 */
@Composable
fun ProvidersPane(model: ProvidersViewModel, focus: FocusRequester, pick: (Picker) -> Unit, onWatch: () -> Unit) {
    when (val screen = model.screen) {
        ProviderScreen.List -> ProviderList(model, focus, pick)
        ProviderScreen.Form -> model.form?.let { ProviderEditor(model, it, focus, pick) }
        is ProviderScreen.Setup -> ProviderSetup(model, screen.providerId, focus, onWatch)
        is ProviderScreen.GuideLinks -> model.guide?.let { GuideLinksPage(model, it, focus, pick) }
    }
}

/** Moves the remote to [target] after the pane changed (the view model asks, once). */
@Composable
private fun TakeFocus(model: ProvidersViewModel, target: FocusRequester) {
    LaunchedEffect(model.takeFocus) {
        if (!model.takeFocus) return@LaunchedEffect
        // A frame for a list's rows to exist, then again a little later if that was too soon.
        withFrameNanos {}
        if (runCatching { target.requestFocus() }.isFailure) {
            delay(150)
            runCatching { target.requestFocus() }
        }
        model.takeFocus = false
    }
}

@Composable
private fun ProviderList(model: ProvidersViewModel, focus: FocusRequester, pick: (Picker) -> Unit) {
    val state = model.state
    // Back from editing or adding a provider, the highlight goes to its row.
    val row = remember { FocusRequester() }
    val returnTo = model.returnTo?.takeIf { id -> state.providers.any { it.id == id } }
    TakeFocus(model, if (returnTo != null) row else focus)
    SettingsPane("Providers", focus) {
        state.message?.let { message ->
            item { SettingRow(message, "OK", valueColor = LumioColors.error, onClick = model::dismissMessage) }
        }
        if (state.loaded && state.providers.isEmpty()) {
            note("Add your IPTV provider to start: its server link, and your username and password. Logins are stored encrypted on this TV only.")
        }
        val draft = model.form?.takeIf { it.providerId == null && it.changed }
        item {
            SettingRow(if (draft != null) "Carry on adding a provider" else "Add provider", "",
                valueColor = LumioColors.accent, onClick = model::startAdding)
        }
        if (state.providers.isNotEmpty()) {
            heading("Your providers")
            items(state.providers, key = { it.id }) { provider ->
                val syncing = state.syncing[provider.id] ?: provider.syncing
                val (value, color) = when {
                    !provider.enabled -> "Off" to LumioColors.secondaryText
                    provider.unreachable -> "Can't connect" to LumioColors.error
                    syncing != null -> syncing to LumioColors.accent
                    provider.problem != null -> "Problem" to LumioColors.warning
                    else -> "On" to LumioColors.accent
                }
                val counts = listOfNotNull(plural(provider.channels, "channel"), plural(provider.movies, "movie"), "${number(provider.series)} series",
                    // Only a note: everything plays without a guide.
                    "no guide".takeIf { provider.guideProblem != null && provider.programmes == 0 },
                    provider.lastRefreshAt?.let { "updated ${updated(it)}" })
                Box(if (provider.id == returnTo) Modifier.focusRequester(row) else Modifier) {
                    SettingRow(provider.name, value, counts.joinToString("  ·  "), valueColor = color) {
                        pick(options(model, provider, state.providers, pick))
                    }
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
    pick: (Picker) -> Unit,
): Picker {
    val index = all.indexOfFirst { it.id == provider.id }
    val actions = buildList {
        add(MenuAction("Refresh now") { model.refresh(provider.id) })
        add(MenuAction("Edit") { model.startEditing(provider) })
        add(MenuAction("Guide links: ${if (provider.guideLinks == 0) "None" else plural(provider.guideLinks, "link")}") { model.openGuideLinks(provider.id) })
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
    add("${plural(provider.channels, "channel")}  ·  ${plural(provider.movies, "movie")}  ·  ${number(provider.series)} series  ·  ${plural(provider.programmes, "programme")}")
    add("Connections: ${provider.connectionsInUse} of ${provider.connectionLimit}")
    provider.expiresAt?.let { add("Expires ${date(it)}") }
    provider.lastRefreshAt?.let { add("Updated ${updated(it)}") }
    for (link in provider.links) {
        add("${link.url}  ·  ${if (link.down) "down" else if (link.inUse) "in use" else "backup"}")
    }
    provider.problem?.let { add(it) }
    provider.guideProblem?.let { add("Guide: $it Channels and films play without one.") }
    add("Guide links are optional: an extra guide (XMLTV) address for channels your provider has no guide for.")
}.joinToString("\n")

private fun date(seconds: Double): String = DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date((seconds * 1000).toLong()))

/** "15 minutes ago", "yesterday". */
private fun updated(seconds: Double): String = android.text.format.DateUtils.getRelativeTimeSpanString(
    (seconds * 1000).toLong(), System.currentTimeMillis(), android.text.format.DateUtils.MINUTE_IN_MILLIS,
).toString().replaceFirstChar { it.lowercase() }

private fun number(count: Int): String = NumberFormat.getIntegerInstance().format(count)

private fun plural(count: Int, one: String) = "${number(count)} $one${if (count == 1) "" else "s"}"

/**
 * Add or change a provider. An empty password keeps the saved one. Back asks before throwing away
 * what was typed; going to another section keeps it for later.
 */
@Composable
private fun ProviderEditor(model: ProvidersViewModel, form: ProviderForm, focus: FocusRequester, pick: (Picker) -> Unit) {
    val adding = form.providerId == null
    val scope = rememberCoroutineScope()
    val first = remember { FocusRequester() }
    val saveButton = remember { FocusRequester() }

    // When the keyboard closes on a link field, read what's in it as the Mac's link box would: a
    // pasted list becomes one row per link, and a login inside a link fills the empty fields.
    fun readLinks(index: Int) {
        val text = form.links.getOrNull(index)?.trim().orEmpty()
        if (text.isEmpty()) return
        scope.launch {
            val parsed = model.parseLinks(text) ?: return@launch
            if (form.links.getOrNull(index)?.trim() != text) return@launch
            form.links.removeAt(index)
            form.links.addAll(index, parsed.links)
            val username = parsed.username
            val password = parsed.password
            if (username != null && password != null &&
                (form.username.isEmpty() || form.username == username) && (form.password.isEmpty() || form.password == password)
            ) {
                form.username = username
                form.password = password
                form.foundLogin = true
            }
        }
    }

    fun leave() {
        if (!form.changed) model.discardForm()
        else pick(Picker(
            if (adding) "Discard this provider?" else "Discard your changes?",
            listOf(MenuAction("Keep editing") {}, MenuAction("Discard") { model.discardForm() }),
            detail = "What you've typed stays while you keep editing, even if you go to another section and come back.",
        ))
    }
    BackHandler(onBack = ::leave)
    TakeFocus(model, first)

    SettingsPane(if (adding) "Add provider" else "Edit ${form.name.ifBlank { "provider" }}", focus, form.message) {
        if (adding && model.state.loaded && model.state.providers.isEmpty()) {
            note("Welcome to Lumio. Enter your IPTV provider's details: the server link, your username and your password. Your login is stored encrypted on this TV only.")
        }
        item {
            Field("Name (optional)", form.name, modifier = Modifier.focusRequester(first)) {
                form.name = it
                form.changed = true
            }
        }
        items(form.links.size) { index ->
            Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                RemoteTextField(
                    if (index == 0) "Server link" else "Backup link $index",
                    form.links[index], placeholder = if (index == 0) "http://example.com:8080" else null,
                    keyboard = KeyboardType.Uri, modifier = Modifier.weight(1f),
                    onEditingDone = { readLinks(index) },
                ) {
                    form.links[index] = it
                    form.changed = true
                }
                if (form.links.size > 1) LumioButton(onClick = {
                    form.links.removeAt(index)
                    form.changed = true
                }) { Text("Remove") }
            }
        }
        item {
            Box(Modifier.padding(start = 16.dp, top = 4.dp)) {
                LumioButton(onClick = {
                    form.links.add("")
                    form.changed = true
                }) { Text("Add a backup link") }
            }
        }
        item {
            Field("Username", form.username) {
                form.username = it
                form.changed = true
            }
        }
        item {
            Field(if (adding) "Password" else "Password (empty keeps the saved one)", form.password, secret = true) {
                form.password = it
                form.changed = true
            }
        }
        if (form.foundLogin) note("Username and password filled in from the link.")
        else note("Backup links are other addresses for the same account: Lumio moves to one when the server in use stops answering. You can paste several links into one field, or an M3U link with your login in it.")
        item {
            // Coming down from the last field lands on Save, not whichever button is nearest.
            Row(
                Modifier.padding(start = 16.dp, top = 16.dp).focusProperties { onEnter = { saveButton.requestFocus() } }.focusGroup(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                // Never disabled while saving: a disabled button loses the remote's highlight.
                LumioButton(modifier = Modifier.focusRequester(saveButton), style = ButtonStyle.Primary, onClick = model::submit) {
                    Text(if (form.saving) "Checking…" else if (adding) "Add" else "Save")
                }
                LumioButton(onClick = ::leave) { Text("Cancel") }
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

// MARK: Guide links

/**
 * A provider's extra guide links: each can be removed, and a new one typed or pasted. Back goes to
 * the provider list. What's typed stays in the view model, so Back and returning lose nothing.
 */
@Composable
private fun GuideLinksPage(model: ProvidersViewModel, form: GuideLinksForm, focus: FocusRequester, pick: (Picker) -> Unit) {
    val first = remember { FocusRequester() }
    BackHandler(onBack = model::closeGuideLinks)
    TakeFocus(model, first)
    val name = model.state.providers.firstOrNull { it.id == form.providerId }?.name
    val links = form.links?.links.orEmpty()

    SettingsPane(if (name != null) "Guide links: $name" else "Guide links", focus) {
        note("Optional. An extra guide (XMLTV) address for channels your provider has no guide for.")
        if (links.isEmpty()) {
            note(if (form.links == null) "Loading…" else "No guide links yet.")
        }
        itemsIndexed(links) { index, link ->
            SettingRow(link, "Remove", valueColor = LumioColors.secondaryText) {
                pick(Picker("Remove this guide link?", listOf(
                    MenuAction("Remove this link") { model.removeGuideLink(index) },
                    MenuAction("Cancel") {},
                ), detail = link))
            }
        }
        item {
            Box(Modifier.padding(start = 16.dp, top = 16.dp).fillMaxWidth()) {
                RemoteTextField(
                    "Add a guide link", form.text, placeholder = "http://…/guide.xml.gz",
                    keyboard = KeyboardType.Uri, modifier = Modifier.fillMaxWidth().focusRequester(first),
                    onEditingDone = { model.addGuideLink() },
                ) {
                    form.text = it
                    form.message = null
                }
            }
        }
        form.message?.let { message ->
            item { Text(message, color = LumioColors.error, fontSize = 15.sp, modifier = Modifier.padding(start = 16.dp, top = 6.dp)) }
        }
        if (form.busy) item { Text("Adding…", color = LumioColors.secondaryText, fontSize = 15.sp, modifier = Modifier.padding(start = 16.dp, top = 6.dp)) }
        form.links?.problem?.let { problem ->
            item { Text("Last update: $problem", color = LumioColors.secondaryText, fontSize = 15.sp, modifier = Modifier.padding(start = 16.dp, top = 10.dp)) }
        }
        note("Lumio matches its channels to yours by guide ID or name and region, and uses them only where your provider has no guide. They update with the guide; the first time can take a minute or two.")
    }
}

// MARK: Setup

/** One line of the setup screen. */
private enum class StepState { Waiting, Working, Done, Failed, Note, Skipped }

private data class SetupStep(val title: String, val state: StepState, val detail: String?, val extra: String? = null)

/** The order a refresh goes through its steps (matching comes between series and the guide). */
private val stepOrder = listOf("account", "live", "movies", "series", "matching", "guide")

/**
 * A new provider's first load, as TiviMate shows a playlist being added: signing in, then
 * channels, films, series and the guide, each ticked off with what it found. A missing guide is a
 * note, not a failure. A refused login offers to change the details (the form, as it was typed).
 */
@Composable
private fun ProviderSetup(model: ProvidersViewModel, providerId: String, focus: FocusRequester, onWatch: () -> Unit) {
    val state = model.state
    val provider = state.providers.firstOrNull { it.id == providerId }
    val finished = providerId in state.finished
    val failed = finished && provider?.failedOutright == true
    val current = stepOrder.indexOf(state.steps[providerId] ?: provider?.syncStep).coerceAtLeast(0)
    val liveDone = finished || current > stepOrder.indexOf("live")
    val canWatch = !failed && liveDone && (provider?.channels ?: 0) > 0
    val primary = remember { FocusRequester() }
    var buttonsFocused by remember { mutableStateOf(false) }

    BackHandler { if (failed) model.changeDetails(providerId, provider?.problem) else model.finishSetup() }
    TakeFocus(model, primary)
    // When something new can be done (start watching, or it finished), the highlight moves there.
    LaunchedEffect(canWatch, finished) {
        if (buttonsFocused) {
            delay(50)
            runCatching { primary.requestFocus() }
        }
    }

    fun row(part: String, title: String, done: () -> String?): SetupStep {
        val index = stepOrder.indexOf(part)
        val p = provider
        return when {
            failed -> SetupStep(title, StepState.Skipped, null)
            finished && p != null && part in p.failedParts ->
                if (part == "guide") SetupStep(title, StepState.Note, "Not available from this provider. Channels and films play without it.")
                else SetupStep(title, StepState.Failed, "Didn't load", p.problem)
            finished || index < current -> SetupStep(title, StepState.Done, done())
            index == current -> SetupStep(title, StepState.Working,
                if (part == "guide") state.syncing[providerId]?.takeIf { it.contains("programmes") } ?: "Downloading…" else "Loading…")
            else -> SetupStep(title, StepState.Waiting, null)
        }
    }

    val steps = listOf(
        when {
            failed -> SetupStep("Signing in", StepState.Failed, "Couldn't sign in", provider?.problem)
            finished || current > 0 -> SetupStep("Signing in", StepState.Done, provider?.let { p ->
                listOfNotNull(p.accountStatus, p.expiresAt?.let { "until ${date(it)}" },
                    plural(p.connectionLimit, "connection").takeIf { p.connectionLimit > 0 }).joinToString("  ·  ").ifEmpty { null }
            })
            else -> SetupStep("Signing in", StepState.Working, "Checking your login…")
        },
        row("live", "Channels") { provider?.let { plural(it.channels, "channel") } },
        row("movies", "Movies") { provider?.let { plural(it.movies, "movie") } },
        row("series", "Series") { provider?.let { "${number(it.series)} series" } },
        row("guide", "TV guide") { provider?.let { plural(it.programmes, "programme") } },
    )

    val name = provider?.name ?: "provider"
    val title = when {
        failed -> "Couldn't add $name"
        finished -> "$name is ready"
        else -> "Adding $name"
    }
    SettingsPane(title, focus) {
        // Keyed, so a note appearing above the buttons doesn't rebuild them (and drop the highlight).
        items(steps, key = { it.title }) { StepRow(it) }
        if (canWatch && !finished) note("You can start watching now. The rest keeps loading in the background.")
        if (failed) note("Check the server link, username and password. Change details opens the form as you typed it.")
        item(key = "buttons") {
            // The same buttons stay put while their labels change, so the highlight never drops
            // off a button that went away (it would land on the sidebar).
            val buttons = when {
                failed -> listOf(
                    SetupButton("Change details", ButtonStyle.Primary) { model.changeDetails(providerId, provider?.problem) },
                    SetupButton("Try again") { model.refresh(providerId) },
                )
                canWatch -> listOf(
                    SetupButton("Start watching", ButtonStyle.Primary) {
                        model.finishSetup(stay = false)
                        onWatch()
                    },
                    SetupButton("Back to providers") { model.finishSetup() },
                )
                else -> listOf(SetupButton(if (finished) "Done" else "Back to providers") { model.finishSetup() })
            }
            Row(
                Modifier.padding(start = 16.dp, top = 20.dp).onFocusChanged { buttonsFocused = it.hasFocus }.focusGroup(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                buttons.forEachIndexed { index, button ->
                    key(index) {
                        LumioButton(
                            modifier = if (index == 0) Modifier.focusRequester(primary) else Modifier,
                            style = button.style, onClick = button.run,
                        ) { Text(button.label) }
                    }
                }
            }
        }
    }
}

private class SetupButton(val label: String, val style: ButtonStyle = ButtonStyle.Normal, val run: () -> Unit)

@Composable
private fun StepRow(step: SetupStep) {
    Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp).fillMaxWidth(), verticalAlignment = Alignment.Top) {
        Box(Modifier.width(36.dp).padding(top = 2.dp), contentAlignment = Alignment.CenterStart) {
            when (step.state) {
                StepState.Working -> Spinner()
                StepState.Done -> Text("✓", color = LumioColors.accent, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                StepState.Failed -> Text("✕", color = LumioColors.error, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                StepState.Note -> Text("–", color = LumioColors.secondaryText, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                StepState.Waiting, StepState.Skipped -> Text("•", color = LumioColors.outline, fontSize = 20.sp)
            }
        }
        Column(Modifier.weight(1f)) {
            Text(step.title, fontSize = 19.sp,
                color = if (step.state == StepState.Waiting || step.state == StepState.Skipped) LumioColors.secondaryText else LumioColors.text)
            step.detail?.let {
                Text(it, fontSize = 15.sp, color = if (step.state == StepState.Failed) LumioColors.error else LumioColors.secondaryText)
            }
            step.extra?.let { Text(it, fontSize = 13.sp, color = LumioColors.secondaryText, maxLines = 3) }
        }
    }
}
