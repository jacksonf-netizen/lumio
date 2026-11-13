package com.jackson.lumio.ui.player

import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Text
import com.jackson.lumio.ui.common.LoadingText
import com.jackson.lumio.core.Channel
import com.jackson.lumio.images.RemoteImage
import com.jackson.lumio.ui.LumioColors
import com.jackson.lumio.ui.common.LumioListItem
import kotlinx.coroutines.flow.distinctUntilChanged

/**
 * The channel list over the video, as OK opens it in TiviMate: the group's channels down the left
 * with what's on now, the playing one marked and highlighted. Up and down move, OK switches
 * channel, Back closes it. The video keeps playing behind.
 */
@Composable
fun ChannelListPanel(list: PlayerViewModel.ChannelList, playing: String?, onPick: (Channel) -> Unit, onScroll: (Int) -> Unit) {
    Box(
        Modifier
            .fillMaxSize()
            .background(Brush.horizontalGradient(0f to Color(0xF0101114), 0.45f to Color(0xC0101114), 0.7f to Color.Transparent)),
    ) {
        Column(Modifier.width(600.dp).fillMaxHeight().padding(start = 32.dp, top = 28.dp, end = 16.dp)) {
            Text("Channels", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = 12.dp, bottom = 12.dp))
            // The panel opens at once; a big group's channels are read meanwhile.
            if (list.loading) {
                LoadingText("Loading channels…", Modifier.padding(start = 12.dp, top = 8.dp))
            } else {
                ChannelRows(list, playing, onPick, onScroll)
            }
        }
    }
}

/** The channel rows, once they're read: the playing one in view and highlighted. */
@Composable
private fun ChannelRows(list: PlayerViewModel.ChannelList, playing: String?, onPick: (Channel) -> Unit, onScroll: (Int) -> Unit) {
    val first = remember { FocusRequester() }
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = maxOf(0, list.start - 4))
    LaunchedEffect(Unit) { runCatching { first.requestFocus() } }
    // What's on is read for the rows coming into view.
    LaunchedEffect(listState) {
        snapshotFlow { listState.firstVisibleItemIndex }.distinctUntilChanged().collect { onScroll(it + 5) }
    }
    val now = System.currentTimeMillis() / 1000.0
    LazyColumn(
        state = listState,
        modifier = Modifier.focusProperties { onExit = { cancelFocusChange() } }.focusGroup(),
    ) {
        itemsIndexed(list.channels, key = { _, channel -> channel.id }) { index, channel ->
            val programme = channel.epg?.let { list.nowNext[it]?.now }
            val isPlaying = channel.id == playing
            LumioListItem(
                selected = isPlaying,
                onClick = { onPick(channel) },
                leadingContent = {
                    Box(Modifier.width(96.dp), contentAlignment = Alignment.CenterStart) {
                        Text(channel.number?.toString() ?: "", color = LumioColors.secondaryText, fontSize = 15.sp,
                            modifier = Modifier.width(44.dp))
                        Box(Modifier.padding(start = 46.dp)) { RemoteImage(channel.logo, 40.dp) }
                    }
                },
                headlineContent = {
                    Text(channel.name, fontSize = 18.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                },
                supportingContent = {
                    Column {
                        Text(programme?.title ?: if (channel.epg == null || channel.epg in list.nowNext) "No guide information" else "",
                            color = LumioColors.secondaryText, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (programme != null) {
                            Box(Modifier.padding(top = 4.dp).fillMaxWidth().height(3.dp)
                                .background(Color(0x33FFFFFF), RoundedCornerShape(2.dp))) {
                                Box(Modifier.fillMaxWidth(programme.progress(now)).height(3.dp)
                                    .background(LumioColors.accent, RoundedCornerShape(2.dp)))
                            }
                        }
                    }
                },
                trailingContent = if (isPlaying) ({ Text("▶", color = LumioColors.accent, fontSize = 14.sp) }) else null,
                modifier = Modifier.fillMaxWidth().then(if (index == list.start) Modifier.focusRequester(first) else Modifier),
            )
        }
    }
}
