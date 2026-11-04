package com.jackson.lumio.ui.live

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.tv.material3.ListItem
import androidx.tv.material3.ListItemDefaults
import androidx.tv.material3.Text
import com.jackson.lumio.core.Channel
import com.jackson.lumio.core.NowNext
import com.jackson.lumio.ui.LumioColors

/** Groups on the left; moving onto a group shows its channels on the right, with what's on now. */
@Composable
fun LiveTvScreen(model: LiveTvViewModel = viewModel()) {
    val state = model.state
    Row(Modifier.fillMaxSize()) {
        LazyColumn(
            Modifier.width(300.dp).fillMaxHeight().padding(vertical = 24.dp, horizontal = 12.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            items(state.groups, key = { it.id }) { group ->
                ListItem(
                    selected = group.id == state.selectedGroup,
                    onClick = { model.select(group.id) },
                    headlineContent = { Text(group.name, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 17.sp) },
                    colors = ListItemDefaults.colors(selectedContainerColor = LumioColors.raised),
                    modifier = Modifier.onFocusChanged { if (it.isFocused) model.select(group.id) },
                )
            }
        }
        Box(Modifier.weight(1f).fillMaxHeight().padding(vertical = 24.dp, horizontal = 12.dp)) {
            when {
                state.message != null -> Text(state.message, color = LumioColors.error)
                !state.loading && state.channels.isEmpty() -> Text(
                    if (state.groups.isEmpty()) "No channels yet. They appear here once your provider has loaded."
                    else "No channels in this group.",
                    color = LumioColors.secondaryText, fontSize = 18.sp,
                )
                else -> LazyColumn(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    items(state.channels, key = { it.id }) { channel ->
                        val nowNext = channel.epg?.let { state.nowNext[it] }
                        LaunchedEffect(channel.epg) { channel.epg?.let(model::wantNowNext) }
                        ChannelRow(channel, nowNext)
                    }
                }
            }
        }
    }
}

@Composable
private fun ChannelRow(channel: Channel, nowNext: NowNext?) {
    val now = System.currentTimeMillis() / 1000.0
    ListItem(
        selected = false,
        // Playback arrives in phase 3.
        onClick = {},
        leadingContent = {
            Text(
                channel.number?.toString() ?: "",
                color = LumioColors.secondaryText, fontSize = 16.sp, modifier = Modifier.width(52.dp),
            )
        },
        headlineContent = { Text(channel.name, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 18.sp) },
        supportingContent = nowNext?.now?.let { programme ->
            {
                Column {
                    val next = nowNext.next?.let { "   ·   Next: ${it.title}" } ?: ""
                    Text(programme.title + next, maxLines = 1, overflow = TextOverflow.Ellipsis, color = LumioColors.secondaryText, fontSize = 14.sp)
                    Box(Modifier.padding(top = 4.dp).width(220.dp).height(3.dp).clip(RoundedCornerShape(2.dp)).background(LumioColors.raised)) {
                        Box(Modifier.fillMaxWidth(programme.progress(now)).fillMaxHeight().background(LumioColors.accent))
                    }
                }
            }
        },
        modifier = Modifier.fillMaxWidth(),
    )
}
