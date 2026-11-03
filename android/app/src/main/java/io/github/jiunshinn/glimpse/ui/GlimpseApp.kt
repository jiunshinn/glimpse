package io.github.jiunshinn.glimpse.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Laptop
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.jiunshinn.glimpse.AppViewModel
import io.github.jiunshinn.glimpse.MacRow
import io.github.jiunshinn.glimpse.MacStatus
import io.github.jiunshinn.glimpse.Pairing
import io.github.jiunshinn.glimpse.SharingService

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GlimpseApp(viewModel: AppViewModel) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val sharing by SharingService.running.collectAsStateWithLifecycle()
    val context = androidx.compose.ui.platform.LocalContext.current
    var scanning by rememberSaveable { mutableStateOf(false) }
    var enteringLink by rememberSaveable { mutableStateOf(false) }
    // The places opened in a Mac's shared folders, last on top. Back goes one step back.
    var places by remember { mutableStateOf(listOf<MacPlace>()) }

    places.lastOrNull()?.let { place ->
        androidx.activity.compose.BackHandler { places = places.dropLast(1) }
        val open: (MacPlace) -> Unit = { places = places + it }
        val back = { places = places.dropLast(1) }
        when (place) {
            is MacPlace.Shared -> SharedFoldersScreen(place, viewModel.browser, open, back)
            is MacPlace.Folder -> FolderScreen(place, viewModel.browser, open, back)
            is MacPlace.Viewer -> MacViewerScreen(place, viewModel.browser, back)
        }
        return
    }

    if (scanning) {
        ScannerScreen(
            onCode = { scanning = false; viewModel.pair(it) },
            onEnterLink = { scanning = false; enteringLink = true },
            onClose = { scanning = false },
        )
        return
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text("Glimpse") }) },
        floatingActionButton = {
            if (state.macs.isNotEmpty()) {
                ExtendedFloatingActionButton(
                    onClick = { scanning = true },
                    icon = { Icon(Icons.Outlined.QrCodeScanner, contentDescription = null) },
                    text = { Text("Pair another Mac") },
                )
            }
        },
    ) { padding ->
        if (state.macs.isEmpty()) {
            EmptyState(Modifier.padding(padding), onScan = { scanning = true }, onEnterLink = { enteringLink = true })
        } else {
            LazyColumn(
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = padding.calculateTopPadding() + 8.dp, bottom = 96.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                item(key = "sharing") {
                    SharingPanel(sharing) { on -> if (on) SharingService.start(context) else SharingService.stop(context) }
                }
                items(state.macs, key = { it.mac.fingerprint }) { row ->
                    MacCard(
                        row,
                        onOpen = { places = listOf(MacPlace.Shared(row.mac.id, row.mac.name)) },
                        onUnpair = { viewModel.unpair(row.mac) },
                        onPairAgain = { scanning = true },
                    )
                }
            }
        }
    }

    if (enteringLink) {
        EnterLinkDialog(
            onPair = { enteringLink = false; viewModel.pair(it) },
            onDismiss = { enteringLink = false },
        )
    }
    PairingDialog(
        pairing = state.pairing,
        onConfirm = viewModel::confirmPairing,
        onRetry = { viewModel.dismissPairing(); scanning = true },
        onDismiss = viewModel::dismissPairing,
    )
}

@Composable
private fun EmptyState(modifier: Modifier, onScan: () -> Unit, onEnterLink: () -> Unit) {
    Column(
        modifier.fillMaxSize().padding(horizontal = 32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            Modifier.size(96.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primaryContainer),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Outlined.Laptop, contentDescription = null, modifier = Modifier.size(48.dp),
                tint = MaterialTheme.colorScheme.onPrimaryContainer,
            )
        }
        Spacer(Modifier.height(24.dp))
        Text("Pair with your Mac", style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(12.dp))
        Text(
            "On your Mac, open Glimpse and choose File › Connect Phone. Then scan the code that Glimpse shows.",
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(32.dp))
        Button(onClick = onScan, contentPadding = PaddingValues(horizontal = 24.dp, vertical = 14.dp)) {
            Icon(Icons.Outlined.QrCodeScanner, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text("Scan code")
        }
        TextButton(onClick = onEnterLink) { Text("Enter pairing link") }
    }
}

@Composable
private fun MacCard(row: MacRow, onOpen: () -> Unit, onUnpair: () -> Unit, onPairAgain: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    val (label, color) = when (row.status) {
        MacStatus.Searching -> "Looking for the Mac…" to MaterialTheme.colorScheme.outline
        MacStatus.Connected -> "Connected" to Color(0xFF2E9E5B)
        MacStatus.ConnectedByCable -> "Connected with USB cable" to Color(0xFF2E9E5B)
        MacStatus.Unreachable -> "Not reachable" to MaterialTheme.colorScheme.outline
        MacStatus.UnpairedByMac -> "The Mac removed this phone. Pair again." to MaterialTheme.colorScheme.error
    }
    val connected = row.status == MacStatus.Connected || row.status == MacStatus.ConnectedByCable
    Card(onClick = onOpen, enabled = connected, modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.padding(start = 16.dp, top = 16.dp, bottom = 16.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Laptop, contentDescription = null, modifier = Modifier.size(32.dp))
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f).semantics(mergeDescendants = true) { contentDescription = "${row.mac.name}, $label" }) {
                Text(row.mac.name, style = MaterialTheme.typography.titleMedium)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(8.dp).clip(CircleShape).background(color))
                    Spacer(Modifier.width(6.dp))
                    Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                val hint = when (row.status) {
                    MacStatus.Connected, MacStatus.ConnectedByCable -> "Tap to browse the folders that the Mac shares."
                    MacStatus.Unreachable -> "Open Glimpse on the Mac, and use the same Wi-Fi network as the Mac."
                    else -> null
                }
                if (hint != null) {
                    Text(hint, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Box {
                IconButton(onClick = { menu = true }) {
                    Icon(Icons.Outlined.MoreVert, contentDescription = "More for ${row.mac.name}")
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    if (row.status == MacStatus.UnpairedByMac) {
                        DropdownMenuItem(text = { Text("Pair again") }, onClick = { menu = false; onPairAgain() })
                    }
                    DropdownMenuItem(text = { Text("Unpair") }, onClick = { menu = false; onUnpair() })
                }
            }
        }
    }
}

@Composable
private fun EnterLinkDialog(onPair: (String) -> Unit, onDismiss: () -> Unit) {
    var text by rememberSaveable { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Enter pairing link") },
        text = {
            Column {
                Text("Use this when the camera cannot scan the code. The link starts with glimpse://pair.")
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(value = text, onValueChange = { text = it }, singleLine = true, placeholder = { Text("glimpse://pair?…") })
            }
        },
        confirmButton = { TextButton(onClick = { onPair(text) }, enabled = text.isNotBlank()) { Text("Pair") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun PairingDialog(pairing: Pairing, onConfirm: () -> Unit, onRetry: () -> Unit, onDismiss: () -> Unit) {
    when (pairing) {
        Pairing.Idle -> Unit
        Pairing.Working -> AlertDialog(
            onDismissRequest = {},
            confirmButton = {},
            text = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(24.dp))
                    Spacer(Modifier.width(16.dp))
                    Text("Connecting to the Mac…")
                }
            },
        )
        is Pairing.Confirm -> AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("Pair with ${pairing.macName}?") },
            text = { Text("The Mac can then see this phone's photos, and this phone can see the Mac's shared folders.") },
            confirmButton = { TextButton(onClick = onConfirm) { Text("Pair") } },
            dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        )
        is Pairing.Done -> AlertDialog(
            onDismissRequest = onDismiss,
            icon = { Icon(Icons.Outlined.CheckCircle, contentDescription = null) },
            title = { Text("Paired with ${pairing.macName}") },
            text = { Text("The phone connects automatically when both devices use the same Wi-Fi network.") },
            confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        )
        is Pairing.Failed -> AlertDialog(
            onDismissRequest = onDismiss,
            icon = { Icon(Icons.Outlined.ErrorOutline, contentDescription = null) },
            title = { Text("Could not pair") },
            text = { Text(pairing.message) },
            confirmButton = { TextButton(onClick = onRetry) { Text("Scan again") } },
            dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } },
        )
    }
}
