package io.github.jiunshinn.glimpse.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.FolderShared
import androidx.compose.material.icons.outlined.PlayCircle
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.jiunshinn.glimpse.MacBrowser
import io.github.jiunshinn.glimpse.peer.RemoteAlbum
import io.github.jiunshinn.glimpse.peer.RemoteItem
import kotlinx.coroutines.launch

/** Where the user is in a Mac's shared folders. */
sealed interface MacPlace {
    data class Shared(val macId: String, val macName: String) : MacPlace
    data class Folder(val macId: String, val album: RemoteAlbum, val path: String, val title: String) : MacPlace
    data class Viewer(val macId: String, val items: List<RemoteItem>, val index: Int) : MacPlace
}

/** A list or an error, while it loads. */
private sealed interface Loaded<out T> {
    data object Loading : Loaded<Nothing>
    data class Ready<T>(val value: T) : Loaded<T>
    data class Failed(val message: String) : Loaded<Nothing>
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SharedFoldersScreen(place: MacPlace.Shared, browser: MacBrowser, onOpen: (MacPlace) -> Unit, onBack: () -> Unit) {
    val albums by produceState<Loaded<List<RemoteAlbum>>>(Loaded.Loading, place) {
        value = runCatching { Loaded.Ready(browser.albums(place.macId)) }.getOrElse { Loaded.Failed(it.message ?: "Error") }
    }
    Scaffold(topBar = { TopAppBar(title = { Text(place.macName) }, navigationIcon = { BackButton(onBack) }) }) { padding ->
        when (val state = albums) {
            Loaded.Loading -> Centered(padding) { CircularProgressIndicator() }
            is Loaded.Failed -> Centered(padding) { Message("Glimpse could not reach the Mac. ${state.message}") }
            is Loaded.Ready -> if (state.value.isEmpty()) {
                Centered(padding) {
                    Message("No folders are shared yet. On the Mac, right-click a folder in the Glimpse sidebar and choose Share with Phone.")
                }
            } else {
                LazyColumn(contentPadding = padding) {
                    items(state.value, key = { it.id }) { album ->
                        ListItem(
                            headlineContent = { Text(album.name) },
                            supportingContent = { Text(if (album.count == 1) "1 item" else "${album.count} items") },
                            leadingContent = { Icon(Icons.Outlined.FolderShared, contentDescription = null) },
                            modifier = Modifier.clickable { onOpen(MacPlace.Folder(place.macId, album, "", album.name)) },
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderScreen(place: MacPlace.Folder, browser: MacBrowser, onOpen: (MacPlace) -> Unit, onBack: () -> Unit) {
    val items by produceState<Loaded<List<RemoteItem>>>(Loaded.Loading, place) {
        value = runCatching { Loaded.Ready(browser.items(place.macId, place.album.id, place.path)) }
            .getOrElse { Loaded.Failed(it.message ?: "Error") }
    }
    Scaffold(topBar = { TopAppBar(title = { Text(place.title) }, navigationIcon = { BackButton(onBack) }) }) { padding ->
        when (val state = items) {
            Loaded.Loading -> Centered(padding) { CircularProgressIndicator() }
            is Loaded.Failed -> Centered(padding) { Message("Glimpse could not reach the Mac. ${state.message}") }
            is Loaded.Ready -> {
                val folders = state.value.filter { it.isFolder }
                val files = state.value.filterNot { it.isFolder }
                if (state.value.isEmpty()) {
                    Centered(padding) { Message("This folder has no photos, videos or documents.") }
                } else {
                    LazyVerticalGrid(
                        columns = GridCells.Adaptive(112.dp),
                        contentPadding = PaddingValues(start = 8.dp, end = 8.dp, top = padding.calculateTopPadding() + 4.dp, bottom = 24.dp),
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        items(folders, key = { "folder/" + it.path }, span = { GridItemSpan(maxLineSpan) }) { folder ->
                            ListItem(
                                headlineContent = { Text(folder.name) },
                                supportingContent = { Text(if (folder.count == 1) "1 item" else "${folder.count} items") },
                                leadingContent = { Icon(Icons.Outlined.Folder, contentDescription = null) },
                                modifier = Modifier.clickable {
                                    onOpen(MacPlace.Folder(place.macId, place.album, folder.path, folder.name))
                                },
                            )
                        }
                        items(files, key = { it.id }) { item ->
                            Tile(place.macId, item, browser) { onOpen(MacPlace.Viewer(place.macId, files, files.indexOf(item))) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Tile(macId: String, item: RemoteItem, browser: MacBrowser, onClick: () -> Unit) {
    Box(
        Modifier.aspectRatio(1f).clip(RoundedCornerShape(6.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant).clickable(onClick = onClick),
    ) {
        RemotePreview(macId, item, browser, size = 384, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        when (item.kind) {
            "video" -> Icon(
                Icons.Outlined.PlayCircle, contentDescription = "Video",
                tint = Color.White, modifier = Modifier.align(Alignment.BottomStart).padding(6.dp).size(22.dp),
            )
            "document" -> Text(
                item.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelSmall,
                color = Color.White,
                modifier = Modifier.align(Alignment.BottomStart).fillMaxWidth().background(Color.Black.copy(alpha = 0.55f))
                    .padding(horizontal = 6.dp, vertical = 3.dp),
            )
        }
    }
}

/** Full-screen previews to swipe through, with pinch to zoom and Save to phone. */
@Composable
fun MacViewerScreen(place: MacPlace.Viewer, browser: MacBrowser, onBack: () -> Unit) {
    val pager = rememberPagerState(initialPage = place.index) { place.items.size }
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    var saving by remember { mutableStateOf(false) }
    Scaffold(snackbarHost = { SnackbarHost(snackbar) }, containerColor = Color.Black) { _ ->
        Box(Modifier.fillMaxSize()) {
            HorizontalPager(state = pager, modifier = Modifier.fillMaxSize(), key = { place.items[it].id }) { page ->
                ZoomableBox { RemotePreview(place.macId, place.items[page], browser, size = 2048, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize()) }
            }
            val item = place.items[pager.currentPage]
            Row(
                Modifier.fillMaxWidth().background(Color.Black.copy(alpha = 0.45f)).safeDrawingPadding().padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back", tint = Color.White) }
                Column(Modifier.weight(1f)) {
                    Text(item.name, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${pager.currentPage + 1} of ${place.items.size}", color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.bodySmall)
                }
                if (saving) {
                    CircularProgressIndicator(Modifier.padding(12.dp).size(24.dp), color = Color.White, strokeWidth = 2.dp)
                } else {
                    IconButton(onClick = {
                        saving = true
                        scope.launch {
                            val message = runCatching { "Saved to ${browser.save(place.macId, item)}" }
                                .getOrElse { "Could not save: ${it.message}" }
                            saving = false
                            snackbar.showSnackbar(message)
                        }
                    }) { Icon(Icons.Outlined.Download, contentDescription = "Save to phone", tint = Color.White) }
                }
            }
            if (item.kind == "video") {
                Text(
                    "Save the video to the phone to play it.",
                    color = Color.White, textAlign = TextAlign.Center,
                    modifier = Modifier.align(Alignment.BottomCenter).safeDrawingPadding().padding(24.dp)
                        .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(8.dp)).padding(12.dp),
                )
            }
        }
    }
}

@Composable
private fun ZoomableBox(content: @Composable () -> Unit) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    Box(
        Modifier.fillMaxSize()
            .pointerInput(Unit) {
                detectTransformGestures { _, pan, zoom, _ ->
                    scale = (scale * zoom).coerceIn(1f, 6f)
                    offset = if (scale == 1f) Offset.Zero else offset + pan
                }
            }
            .graphicsLayer(scaleX = scale, scaleY = scale, translationX = offset.x, translationY = offset.y),
    ) { content() }
}

@Composable
private fun RemotePreview(macId: String, item: RemoteItem, browser: MacBrowser, size: Int, contentScale: ContentScale, modifier: Modifier) {
    val image by produceState(browser.cachedPreview(macId, item.id, size) ?: browser.cachedPreview(macId, item.id, 384), item.id, size) {
        browser.preview(macId, item.id, size)?.let { value = it }
    }
    val bitmap = image
    if (bitmap != null) {
        Image(bitmap, contentDescription = item.name, contentScale = contentScale, modifier = modifier)
    } else if (item.kind == "document") {
        Box(modifier, contentAlignment = Alignment.Center) {
            Icon(Icons.Outlined.Description, contentDescription = item.name, modifier = Modifier.size(40.dp))
        }
    } else {
        Box(modifier)
    }
}

@Composable
private fun BackButton(onBack: () -> Unit) {
    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back") }
}

@Composable
private fun Centered(padding: PaddingValues, content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize().padding(padding).padding(32.dp), contentAlignment = Alignment.Center) { content() }
}

@Composable
private fun Message(text: String) {
    Text(text, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant)
}
