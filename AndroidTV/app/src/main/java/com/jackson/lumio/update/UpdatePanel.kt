package com.jackson.lumio.update

import android.content.ActivityNotFoundException
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.sp
import androidx.tv.material3.Text
import com.jackson.lumio.ui.LumioColors
import com.jackson.lumio.ui.common.MenuAction
import com.jackson.lumio.ui.common.OptionsPanel

/** The update offer and its progress, on the right of the screen. Back closes it (and stops a download). */
@Composable
fun UpdatePanel(model: UpdateViewModel) {
    val context = LocalContext.current
    val state = model.state
    val (title, detail, actions) = when (state) {
        is UpdateState.Available -> Triple(
            "Lumio ${state.info.latest} is available",
            state.info.summary.orEmpty(),
            listOf(
                MenuAction("Update now") { model.install(state.info) },
                MenuAction("Later") { model.later() },
                MenuAction("Skip this version") { model.skip(state.info) },
            ),
        )
        is UpdateState.Downloading -> Triple(
            "Downloading Lumio ${state.info.latest}",
            state.fraction?.let { "${(it * 100).toInt()}% downloaded" } ?: "Starting the download…",
            listOf(MenuAction("Cancel") { model.dismiss() }),
        )
        is UpdateState.NeedsPermission -> Triple(
            "Allow Lumio to install its update",
            "Android needs your permission once. On the next screen, switch on Lumio, then press Back to return here.",
            listOf(
                MenuAction("Open settings") {
                    try {
                        context.startActivity(model.permissionIntent())
                    } catch (_: ActivityNotFoundException) {
                        model.dismiss()
                    }
                },
                MenuAction("Cancel") { model.dismiss() },
            ),
        )
        is UpdateState.Installing -> Triple(
            "Installing Lumio ${state.info.latest}",
            "Android asks you to confirm. Choose Install; Lumio closes and the new version opens.",
            listOf(MenuAction("Hide") { model.later() }),
        )
        is UpdateState.Failed -> Triple("Lumio couldn't update", state.message, listOf(MenuAction("OK") { model.dismiss() }))
        else -> return
    }
    // A fresh panel (and highlight) for each step.
    key(state::class) {
        OptionsPanel(
            title = title,
            actions = actions,
            onDismiss = { model.dismiss() },
            detail = { Column { Text(detail, color = LumioColors.secondaryText, fontSize = 15.sp) } },
            closeOnChoice = false,
        )
    }
}
