package io.github.jiunshinn.glimpse.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.Card
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

/** What the Mac can see on this phone, and the switch that shares it. */
@Composable
fun SharingPanel(sharing: Boolean, onSharingChange: (Boolean) -> Unit) {
    val context = LocalContext.current
    // Read the permissions again when the user comes back from Settings.
    var refresh by remember { mutableIntStateOf(0) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) refresh++ }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    val media = remember(refresh) { mediaAccess(context) }
    val files = remember(refresh) { Environment.isExternalStorageManager() }
    val askMedia = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { refresh++ }
    val askNotifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { onSharingChange(true) }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Share with your Mac", style = MaterialTheme.typography.titleMedium)
                    Text(
                        if (sharing) "Your Mac can browse this phone now." else "Turn on to browse this phone in Glimpse on your Mac.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(checked = sharing, onCheckedChange = { on ->
                    val needsNotificationPermission = Build.VERSION.SDK_INT >= 33 &&
                        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    if (on && needsNotificationPermission) askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                    else onSharingChange(on)
                })
            }
            AccessRow(
                icon = Icons.Outlined.PhotoLibrary,
                title = "Photos and videos",
                detail = when (media) {
                    MediaAccess.All -> "All albums"
                    MediaAccess.Selected -> "Only the photos you selected"
                    MediaAccess.None -> "Not allowed"
                },
                allowed = media == MediaAccess.All,
                action = if (media == MediaAccess.All) null else "Allow",
                onAction = {
                    askMedia.launch(arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO))
                },
            )
            AccessRow(
                icon = Icons.Outlined.Folder,
                title = "Folders and files",
                detail = if (files) "All folders, such as Download and Documents" else "Needs All files access",
                allowed = files,
                action = if (files) null else "Allow",
                onAction = {
                    context.startActivity(
                        Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:${context.packageName}"))
                    )
                },
            )
        }
    }
}

@Composable
private fun AccessRow(icon: ImageVector, title: String, detail: String, allowed: Boolean, action: String?, onAction: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (allowed) {
            Icon(Icons.Outlined.CheckCircle, contentDescription = "Allowed", tint = MaterialTheme.colorScheme.primary)
        } else if (action != null) {
            FilledTonalButton(onClick = onAction) { Text(action) }
        }
    }
}

private enum class MediaAccess { All, Selected, None }

private fun mediaAccess(context: Context): MediaAccess {
    fun granted(permission: String) = ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    return when {
        granted(Manifest.permission.READ_MEDIA_IMAGES) && granted(Manifest.permission.READ_MEDIA_VIDEO) -> MediaAccess.All
        Build.VERSION.SDK_INT >= 34 && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> MediaAccess.Selected
        else -> MediaAccess.None
    }
}
