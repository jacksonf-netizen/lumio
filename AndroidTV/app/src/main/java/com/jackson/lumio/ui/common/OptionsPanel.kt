package com.jackson.lumio.ui.common

import androidx.activity.compose.BackHandler
import com.jackson.lumio.ui.common.LumioListItem
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Text
import com.jackson.lumio.ui.LumioColors

/** One choice in an [OptionsPanel]. [selected] marks the current one (a group picker's group). */
data class MenuAction(val label: String, val selected: Boolean = false, val run: () -> Unit)

/**
 * A list of choices on the right of the screen, over what's there: what Hold OK opens on a channel,
 * and the guide's group picker. The remote stays inside until a choice is made or Back closes it.
 */
@Composable
fun OptionsPanel(
    title: String,
    actions: List<MenuAction>,
    onDismiss: () -> Unit,
    detail: (@Composable () -> Unit)? = null,
    /** False for a list of switches: a choice runs and the panel stays (Back closes it). */
    closeOnChoice: Boolean = true,
) {
    val first = remember { FocusRequester() }
    val start = actions.indexOfFirst { it.selected }.coerceAtLeast(0)
    LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
    BackHandler(onBack = onDismiss)
    Box(Modifier.fillMaxSize().background(Color(0x99030814)), contentAlignment = Alignment.CenterEnd) {
        Column(
            Modifier
                .width(440.dp)
                .fillMaxHeight()
                .background(LumioColors.surface)
                .padding(horizontal = 24.dp, vertical = 28.dp)
                .focusProperties { onExit = { cancelFocusChange() } }
                .focusGroup(),
        ) {
            Text(title, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, maxLines = 2,
                overflow = TextOverflow.Ellipsis)
            if (detail != null) Box(Modifier.padding(top = 10.dp)) { detail() }
            LazyColumn(
                Modifier.padding(top = 16.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
                // Opens scrolled to the current choice.
                state = androidx.compose.foundation.lazy.rememberLazyListState(initialFirstVisibleItemIndex = maxOf(0, start - 3)),
            ) {
                itemsIndexed(actions) { index, action ->
                    LumioListItem(
                        selected = action.selected,
                        onClick = {
                            if (closeOnChoice) onDismiss()
                            action.run()
                        },
                        headlineContent = { Text(action.label, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        trailingContent = if (action.selected) ({ Text("✓", color = LumioColors.accent) }) else null,
                        modifier = Modifier.fillMaxWidth().then(if (index == start) Modifier.focusRequester(first) else Modifier),
                    )
                }
            }
        }
    }
}
