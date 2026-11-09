package com.jackson.lumio.ui.common

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Text
import com.jackson.lumio.ui.LumioColors

/**
 * A labelled text field for the remote: up and down move past it, OK opens the on-screen keyboard,
 * and the keyboard's done key (or Back) closes it again. The keyboard doesn't open just because
 * the field has focus, so moving through a form never traps the remote in the keyboard.
 */
@Composable
fun RemoteTextField(
    label: String?,
    value: String,
    placeholder: String? = null,
    secret: Boolean = false,
    keyboard: KeyboardType = KeyboardType.Text,
    imeAction: ImeAction = ImeAction.Done,
    modifier: Modifier = Modifier,
    /** Opens the keyboard straight away (Search). */
    startEditing: Boolean = false,
    /** Called when the keyboard closes (done, Back, or moving off the field). */
    onEditingDone: () -> Unit = {},
    onChange: (String) -> Unit,
) {
    var editing by remember { mutableStateOf(startEditing) }
    var wasEditing by remember { mutableStateOf(startEditing) }
    val editingDone by rememberUpdatedState(onEditingDone)
    var hadFocus by remember { mutableStateOf(false) }
    var highlighted by remember { mutableStateOf(false) }
    val box = remember { FocusRequester() }
    val text = remember { FocusRequester() }
    val keyboardController = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current

    LaunchedEffect(editing) {
        if (editing) {
            text.requestFocus()
            keyboardController?.show()
        } else if (wasEditing) {
            editingDone()
        }
        wasEditing = editing
    }

    Column(modifier) {
        if (label != null) {
            Text(label, color = LumioColors.secondaryText, fontSize = 15.sp)
            Spacer(Modifier.height(4.dp))
        }
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
                    imeAction = imeAction,
                    autoCorrectEnabled = false,
                ),
                keyboardActions = KeyboardActions(onDone = {
                    editing = false
                    box.requestFocus()
                }, onSearch = {
                    editing = false
                    box.requestFocus()
                }),
                decorationBox = { field ->
                    if (value.isEmpty() && placeholder != null) Text(placeholder, color = LumioColors.secondaryText, fontSize = 18.sp)
                    field()
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .focusRequester(text)
                    .focusProperties { canFocus = editing }
                    // Reported once unfocused when the field appears, so only a real loss of focus counts.
                    .onFocusChanged {
                        if (it.isFocused) hadFocus = true
                        else if (hadFocus && editing) {
                            hadFocus = false
                            editing = false
                        }
                    }
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
                            // Back with the keyboard already closed leaves the field and carries on
                            // (to the sidebar, or closing a form) instead of using up a press.
                            Key.Back -> {
                                editing = false
                                box.requestFocus()
                                false
                            }
                            else -> false
                        }
                    },
            )
        }
    }
}
