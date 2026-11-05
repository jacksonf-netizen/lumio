package com.jackson.lumio.images

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp

/** A logo or poster from [url], fitted into a [size] square; empty until it loads (or if it can't). */
@Composable
fun RemoteImage(url: String?, size: Dp, modifier: Modifier = Modifier) {
    val sizePx = with(LocalDensity.current) { size.roundToPx() }
    val bitmap by produceState(initialValue = url?.let { ImageLoader.cached(it, sizePx) }, url, sizePx) {
        if (value == null && url != null) value = ImageLoader.load(url, sizePx)
    }
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        bitmap?.let { Image(it.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Fit) }
    }
}
