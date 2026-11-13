package com.jackson.lumio.ui.common

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Text
import com.jackson.lumio.ui.LumioColors

/** A turning arc, to show something is loading. */
@Composable
internal fun Spinner(diameter: Dp = 20.dp, color: Color = LumioColors.accent) {
    val turn by rememberInfiniteTransition(label = "spinner")
        .animateFloat(0f, 360f, infiniteRepeatable(tween(1000, easing = LinearEasing)), label = "turn")
    Canvas(Modifier.size(diameter)) {
        val width = diameter.toPx() / 8
        rotate(turn) {
            drawArc(
                color = color, startAngle = 0f, sweepAngle = 270f, useCenter = false,
                topLeft = Offset(width / 2, width / 2),
                size = Size(size.width - width, size.height - width),
                style = Stroke(width = width, cap = StrokeCap.Round),
            )
        }
    }
}

/** A wheel with a line of text beside it, for "Loading…" messages (so loading always shows movement). */
@Composable
fun LoadingText(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = LumioColors.secondaryText,
    fontSize: TextUnit = 18.sp,
    spinner: Dp = 20.dp,
) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Spinner(spinner)
        Text(text, color = color, fontSize = fontSize)
    }
}
