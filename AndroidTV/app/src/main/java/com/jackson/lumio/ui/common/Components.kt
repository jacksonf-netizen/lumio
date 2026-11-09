package com.jackson.lumio.ui.common

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Border
import androidx.tv.material3.Button
import androidx.tv.material3.ButtonDefaults
import androidx.tv.material3.CardDefaults
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.ListItem
import androidx.tv.material3.ListItemDefaults
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import com.jackson.lumio.ui.LumioColors

/** Shapes used across the app, so rows, cards and buttons round off the same way. */
object LumioShapes {
    val row = RoundedCornerShape(10.dp)
    val card = RoundedCornerShape(10.dp)
    val button = RoundedCornerShape(10.dp)
    val pill = RoundedCornerShape(50)
}

/** The cyan outline that shows where the remote is, on rows and posters. */
fun focusBorder(shape: androidx.compose.ui.graphics.Shape = LumioShapes.row) =
    Border(BorderStroke(2.dp, LumioColors.accent), shape = shape)

/**
 * A row in a list (groups, channels, settings, choices). At rest it's flat; under the highlight it
 * lifts to a lighter grey with a cyan outline. [selected] marks the current one (cyan text).
 */
@Composable
fun LumioListItem(
    selected: Boolean,
    onClick: () -> Unit,
    headlineContent: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onLongClick: (() -> Unit)? = null,
    supportingContent: (@Composable () -> Unit)? = null,
    leadingContent: (@Composable androidx.compose.foundation.layout.BoxScope.() -> Unit)? = null,
    trailingContent: (@Composable () -> Unit)? = null,
) {
    ListItem(
        selected = selected,
        onClick = onClick,
        onLongClick = onLongClick,
        enabled = enabled,
        headlineContent = headlineContent,
        supportingContent = supportingContent,
        leadingContent = leadingContent,
        trailingContent = trailingContent,
        shape = ListItemDefaults.shape(LumioShapes.row),
        colors = ListItemDefaults.colors(
            containerColor = Color.Transparent,
            contentColor = LumioColors.text,
            focusedContainerColor = LumioColors.focus,
            focusedContentColor = Color.White,
            pressedContainerColor = LumioColors.focus,
            pressedContentColor = Color.White,
            selectedContainerColor = LumioColors.raised,
            selectedContentColor = LumioColors.accent,
            focusedSelectedContainerColor = LumioColors.focus,
            focusedSelectedContentColor = LumioColors.accent,
            pressedSelectedContainerColor = LumioColors.focus,
            pressedSelectedContentColor = LumioColors.accent,
        ),
        border = ListItemDefaults.border(
            focusedBorder = focusBorder(),
            focusedSelectedBorder = focusBorder(),
            pressedBorder = focusBorder(),
            pressedSelectedBorder = focusBorder(),
        ),
        scale = ListItemDefaults.scale(focusedScale = 1f, focusedSelectedScale = 1f, pressedScale = 1f, pressedSelectedScale = 1f),
        modifier = modifier,
    )
}

/** How a [LumioButton] looks: the main action, an ordinary one, or one that deletes something. */
enum class ButtonStyle { Primary, Normal, Destructive }

/** A button: a grey pill at rest, filled cyan under the highlight (red for [ButtonStyle.Destructive]). */
@Composable
fun LumioButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    style: ButtonStyle = ButtonStyle.Normal,
    content: @Composable RowScope.() -> Unit,
) {
    val fill = if (style == ButtonStyle.Destructive) LumioColors.error else LumioColors.accent
    Button(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        shape = ButtonDefaults.shape(LumioShapes.button),
        colors = ButtonDefaults.colors(
            containerColor = LumioColors.raised,
            contentColor = if (style == ButtonStyle.Primary) LumioColors.accent else LumioColors.text,
            focusedContainerColor = fill,
            focusedContentColor = LumioColors.onAccent,
            pressedContainerColor = fill,
            pressedContentColor = LumioColors.onAccent,
            disabledContainerColor = LumioColors.raised.copy(alpha = 0.5f),
            disabledContentColor = LumioColors.secondaryText,
        ),
        scale = ButtonDefaults.scale(focusedScale = 1.04f),
        contentPadding = PaddingValues(horizontal = 22.dp, vertical = 10.dp),
        content = content,
    )
}

/** The border every poster and tile card uses under the highlight. */
@Composable
fun lumioCardBorder() = CardDefaults.border(focusedBorder = Border(BorderStroke(3.dp, LumioColors.accent), shape = LumioShapes.card))

/**
 * Tabs along the top of a page (Movies / Series). Moving onto a tab shows it; the current one is
 * cyan, and the remote's highlight fills it.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun LumioTabs(titles: List<String>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    Row(modifier.focusRestorer(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        titles.forEachIndexed { index, title ->
            val current = index == selected
            Surface(
                onClick = { onSelect(index) },
                modifier = Modifier.onFocusChanged { if (it.isFocused && !current) onSelect(index) },
                shape = ClickableSurfaceDefaults.shape(LumioShapes.pill),
                colors = ClickableSurfaceDefaults.colors(
                    containerColor = if (current) LumioColors.raised else Color.Transparent,
                    contentColor = if (current) LumioColors.accent else LumioColors.secondaryText,
                    focusedContainerColor = LumioColors.accent,
                    focusedContentColor = LumioColors.onAccent,
                ),
                scale = ClickableSurfaceDefaults.scale(focusedScale = 1f),
            ) {
                Text(title, fontSize = 18.sp, fontWeight = FontWeight.Medium, modifier = Modifier.padding(horizontal = 22.dp, vertical = 9.dp))
            }
        }
    }
}

/** A page's title, top left. */
@Composable
fun PageTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, fontSize = 30.sp, fontWeight = FontWeight.SemiBold, color = LumioColors.text, modifier = modifier)
}

/** A small heading over a group of rows. */
@Composable
fun SectionHeading(text: String, modifier: Modifier = Modifier) {
    Text(text, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = LumioColors.secondaryText, modifier = modifier)
}
