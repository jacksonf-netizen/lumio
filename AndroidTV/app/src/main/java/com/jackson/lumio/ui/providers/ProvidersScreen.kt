package com.jackson.lumio.ui.providers

import androidx.compose.foundation.background
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.focus.focusProperties
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Button
import androidx.tv.material3.ButtonDefaults
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Surface
import androidx.tv.material3.SurfaceDefaults
import androidx.tv.material3.Text
import com.jackson.lumio.core.ProviderInfo
import com.jackson.lumio.ui.LumioColors
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.launch

/** What the Providers screen shows: the list, or the editor for a new or existing provider. */
private sealed interface ProvidersPage {
    data object List : ProvidersPage
    data class Edit(val provider: ProviderInfo?) : ProvidersPage
}

@Composable
fun ProvidersScreen(model: ProvidersViewModel) {
    var page by remember { mutableStateOf<ProvidersPage>(ProvidersPage.List) }
    when (val current = page) {
        ProvidersPage.List -> ProviderList(
            model,
            onAdd = { page = ProvidersPage.Edit(null) },
            onEdit = { page = ProvidersPage.Edit(it) },
        )
        is ProvidersPage.Edit -> ProviderEditorPage(model, current.provider, onDone = { page = ProvidersPage.List })
    }
}

@Composable
private fun ProviderList(model: ProvidersViewModel, onAdd: () -> Unit, onEdit: (ProviderInfo) -> Unit) {
    val state = model.state
    val addButton = remember { FocusRequester() }
    // The remote starts on "Add provider" (on first run, and back from the editor).
    LaunchedEffect(state.loaded) {
        if (state.loaded) runCatching { addButton.requestFocus() }
    }
    Column(Modifier.fillMaxSize().padding(horizontal = 48.dp, vertical = 32.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Providers", fontSize = 30.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            if (state.providers.isNotEmpty()) {
                OutlinedButton(onClick = { model.refresh() }) { Text("Refresh all") }
                Spacer(Modifier.padding(6.dp))
            }
            Button(onClick = onAdd, modifier = Modifier.focusRequester(addButton)) { Text("Add provider") }
        }
        state.message?.let { message ->
            Spacer(Modifier.height(12.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(message, color = LumioColors.error, modifier = Modifier.weight(1f))
                OutlinedButton(onClick = model::dismissMessage) { Text("OK") }
            }
        }
        Spacer(Modifier.height(20.dp))
        if (state.loaded && state.providers.isEmpty()) {
            Text(
                "Add your IPTV provider to start: its server address and your username and password. " +
                    "Logins are stored encrypted on this device only.",
                color = LumioColors.secondaryText, fontSize = 18.sp,
            )
        }
        LazyColumn(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            items(state.providers, key = { it.id }) { provider ->
                ProviderRow(
                    provider = provider,
                    syncing = state.syncing[provider.id] ?: provider.syncing,
                    isFirst = provider == state.providers.first(),
                    isLast = provider == state.providers.last(),
                    model = model,
                    onEdit = { onEdit(provider) },
                )
            }
        }
    }
}

@Composable
private fun ProviderRow(
    provider: ProviderInfo,
    syncing: String?,
    isFirst: Boolean,
    isLast: Boolean,
    model: ProvidersViewModel,
    onEdit: () -> Unit,
) {
    var confirmRemove by remember { mutableStateOf(false) }
    Surface(
        colors = SurfaceDefaults.colors(containerColor = LumioColors.surface),
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(provider.name, fontSize = 22.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
                when {
                    !provider.enabled -> Text("Off", color = LumioColors.secondaryText)
                    provider.unreachable -> Text("Can't reach any server link", color = LumioColors.error)
                    syncing != null -> Text(syncing, color = LumioColors.accent)
                }
            }
            Spacer(Modifier.height(6.dp))
            Text(statusLine(provider), color = LumioColors.secondaryText, fontSize = 15.sp)
            provider.lastError?.let { Text(it, color = LumioColors.warning, fontSize = 15.sp) }
            Spacer(Modifier.height(8.dp))
            for (link in provider.links) {
                val note = when {
                    link.down -> "Down"
                    link.inUse -> "In use"
                    else -> "Backup"
                }
                Text(
                    "${link.url}  ·  $note",
                    color = if (link.down) LumioColors.error else LumioColors.secondaryText,
                    fontSize = 14.sp,
                )
            }
            Spacer(Modifier.height(14.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (confirmRemove) {
                    Text("Remove ${provider.name} and everything loaded from it?", modifier = Modifier.align(Alignment.CenterVertically))
                    Button(
                        onClick = { model.remove(provider.id) },
                        colors = ButtonDefaults.colors(containerColor = LumioColors.error),
                    ) { Text("Remove") }
                    OutlinedButton(onClick = { confirmRemove = false }) { Text("Cancel") }
                } else {
                    Button(onClick = { model.refresh(provider.id) }) { Text("Refresh") }
                    OutlinedButton(onClick = onEdit) { Text("Edit") }
                    OutlinedButton(onClick = { model.setEnabled(provider.id, !provider.enabled) }) {
                        Text(if (provider.enabled) "Switch off" else "Switch on")
                    }
                    if (!isFirst) OutlinedButton(onClick = { model.move(provider.id, -1) }) { Text("Move up") }
                    if (!isLast) OutlinedButton(onClick = { model.move(provider.id, 1) }) { Text("Move down") }
                    OutlinedButton(onClick = { confirmRemove = true }) { Text("Remove") }
                }
            }
        }
    }
}

private fun statusLine(provider: ProviderInfo): String {
    val parts = mutableListOf(
        "${provider.channels} channels",
        "${provider.movies} movies",
        "${provider.series} series",
        "${provider.programmes} programmes",
        "connections ${provider.connectionsInUse} of ${provider.connectionLimit}",
    )
    provider.expiresAt?.let { parts += "expires ${DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date((it * 1000).toLong()))}" }
    provider.lastRefreshAt?.let {
        parts += "updated ${DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date((it * 1000).toLong()))}"
    }
    return parts.joinToString("  ·  ")
}

/** Add (provider = null) or edit a provider. An empty password keeps the saved one. */
@Composable
private fun ProviderEditorPage(model: ProvidersViewModel, provider: ProviderInfo?, onDone: () -> Unit) {
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

    LaunchedEffect(Unit) { first.requestFocus() }
    LaunchedEffect(provider?.id) {
        if (provider != null) model.editor(provider.id)?.let { editor ->
            links.clear()
            links.addAll(editor.servers.lines().filter { it.isNotBlank() }.ifEmpty { listOf("") })
            username = editor.username
        }
    }

    LazyColumn(
        Modifier.fillMaxSize().padding(horizontal = 48.dp),
        contentPadding = PaddingValues(vertical = 32.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Text(if (provider == null) "Add provider" else "Edit ${provider.name}", fontSize = 30.sp, fontWeight = FontWeight.SemiBold)
        }
        item { Field("Name (optional)", name, modifier = Modifier.focusRequester(first)) { name = it } }
        items(links.size) { index ->
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Field(
                    if (index == 0) "Server link" else "Backup link ${index}",
                    links[index], keyboard = KeyboardType.Uri, modifier = Modifier.weight(1f),
                ) { links[index] = it }
                if (links.size > 1) OutlinedButton(onClick = { links.removeAt(index) }) { Text("Remove") }
            }
        }
        item {
            OutlinedButton(onClick = { links.add("") }) { Text("Add a backup link") }
        }
        item { Field("Username", username) { username = it } }
        item {
            Field(if (provider == null) "Password" else "Password (leave empty to keep the saved one)", password, secret = true) {
                password = it
            }
        }
        message?.let { item { Text(it, color = LumioColors.error) } }
        item {
            // Coming down from the last field lands on Save, not whichever button is nearest.
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.focusProperties { onEnter = { saveButton.requestFocus() } }.focusGroup(),
            ) {
                Button(
                    modifier = Modifier.focusRequester(saveButton),
                    enabled = !saving,
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
                OutlinedButton(onClick = onDone) { Text("Cancel") }
            }
        }
    }
}

/**
 * A labelled text field for the remote: up and down move past it, OK opens the on-screen keyboard,
 * and the keyboard's done key (or Back) closes it again. The keyboard doesn't open just because
 * the field has focus, so moving through a form never traps the remote in the keyboard.
 */
@Composable
private fun Field(
    label: String,
    value: String,
    secret: Boolean = false,
    keyboard: KeyboardType = KeyboardType.Text,
    modifier: Modifier = Modifier,
    onChange: (String) -> Unit,
) {
    var editing by remember { mutableStateOf(false) }
    var highlighted by remember { mutableStateOf(false) }
    val box = remember { FocusRequester() }
    val text = remember { FocusRequester() }
    val keyboardController = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current

    LaunchedEffect(editing) {
        if (editing) {
            text.requestFocus()
            keyboardController?.show()
        }
    }

    Column(modifier) {
        Text(label, color = LumioColors.secondaryText, fontSize = 15.sp)
        Spacer(Modifier.height(4.dp))
        Box(
            Modifier
                .fillMaxWidth()
                .focusRequester(box)
                .onFocusChanged { highlighted = it.hasFocus }
                .clickable { editing = true }
                .background(LumioColors.surface, RoundedCornerShape(8.dp))
                .border(2.dp, if (highlighted) LumioColors.accent else LumioColors.raised, RoundedCornerShape(8.dp))
                .padding(horizontal = 14.dp, vertical = 10.dp),
        ) {
            BasicTextField(
                value = value,
                onValueChange = onChange,
                singleLine = true,
                readOnly = !editing,
                textStyle = TextStyle(color = LumioColors.text, fontSize = 18.sp),
                cursorBrush = SolidColor(if (editing) LumioColors.accent else Color.Transparent),
                visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
                keyboardOptions = KeyboardOptions(
                    keyboardType = if (secret) KeyboardType.Password else keyboard,
                    imeAction = ImeAction.Done,
                    autoCorrectEnabled = false,
                ),
                keyboardActions = KeyboardActions(onDone = {
                    editing = false
                    box.requestFocus()
                }),
                modifier = Modifier
                    .fillMaxWidth()
                    .focusRequester(text)
                    .focusProperties { canFocus = editing }
                    .onFocusChanged { if (!it.isFocused && editing) editing = false }
                    // With the keyboard closed (Back), up and down leave the field and OK reopens it.
                    .onPreviewKeyEvent { event ->
                        if (!editing || event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                        when (event.key) {
                            Key.DirectionDown, Key.DirectionUp -> {
                                editing = false
                                box.requestFocus()
                                focusManager.moveFocus(if (event.key == Key.DirectionDown) FocusDirection.Down else FocusDirection.Up)
                                true
                            }
                            Key.DirectionCenter, Key.Enter -> {
                                keyboardController?.show()
                                true
                            }
                            else -> false
                        }
                    },
            )
        }
    }
}
