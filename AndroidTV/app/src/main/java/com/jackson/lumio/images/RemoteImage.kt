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

/**
 * A poster or still from [url] in a [width] by [height] box, cropped to fill it by default.
 * Decoded at the box's longest side, so a shelf of posters stays small in memory.
 */
@Composable
fun RemoteImage(
    url: String?,
    width: Dp,
    height: Dp,
    modifier: Modifier = Modifier,
    contentScale: ContentScale = ContentScale.Crop,
) {
    val sizePx = with(LocalDensity.current) { maxOf(width, height).roundToPx() }
    val bitmap by produceState(initialValue = url?.let { ImageLoader.cached(it, sizePx) }, url, sizePx) {
        if (value == null && url != null) value = ImageLoader.load(url, sizePx)
    }
    Box(modifier.size(width, height), contentAlignment = Alignment.Center) {
        bitmap?.let {
            Image(it.asImageBitmap(), contentDescription = null, contentScale = contentScale, modifier = Modifier.size(width, height))
        }
    }
}
