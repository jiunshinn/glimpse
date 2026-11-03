package io.github.jiunshinn.glimpse

import android.content.ContentValues
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.MediaStore
import android.util.LruCache
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import io.github.jiunshinn.glimpse.peer.PeerClient
import io.github.jiunshinn.glimpse.peer.PeerException
import io.github.jiunshinn.glimpse.peer.RemoteAlbum
import io.github.jiunshinn.glimpse.peer.RemoteItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext

/** A Mac to browse: its client and the address that answered last (the cable or the network). */
data class MacEndpoint(val client: PeerClient, val host: String, val port: Int)

/**
 * Browses the folders that a paired Mac shares: lists, previews and saving to the phone.
 * [endpoint] gives the Mac's current address, or null when it is not reachable.
 */
class MacBrowser(private val context: Context, private val endpoint: suspend (macId: String) -> MacEndpoint?) {
    private val previews = object : LruCache<String, ImageBitmap>((Runtime.getRuntime().maxMemory() / 8).toInt()) {
        override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 4
    }
    /** At most a few previews load at once, so the visible ones arrive first. */
    private val loads = Semaphore(4)

    suspend fun albums(macId: String): List<RemoteAlbum> {
        val mac = endpoint(macId) ?: throw notReachable()
        return mac.client.albums(mac.host, mac.port)
    }

    suspend fun items(macId: String, albumId: String, path: String): List<RemoteItem> {
        val mac = endpoint(macId) ?: throw notReachable()
        return mac.client.items(mac.host, mac.port, albumId, path)
    }

    fun cachedPreview(macId: String, itemId: String, size: Int): ImageBitmap? = previews.get("$macId/$itemId/$size")

    suspend fun preview(macId: String, itemId: String, size: Int): ImageBitmap? {
        val key = "$macId/$itemId/$size"
        previews.get(key)?.let { return it }
        return loads.withPermit {
            previews.get(key) ?: run {
                val mac = endpoint(macId) ?: return@run null
                val bytes = mac.client.bytes(mac.host, mac.port, "/v1/items/$itemId/thumbnail?size=$size") ?: return@run null
                withContext(Dispatchers.Default) { BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap() }
                    ?.also { previews.put(key, it) }
            }
        }
    }

    /**
     * Saves a file from the Mac on the phone: photos to Pictures/Glimpse, videos to Movies/Glimpse, other files to
     * Download/Glimpse. Returns the folder it went to. MediaStore needs no permission for the app's own files.
     */
    suspend fun save(macId: String, item: RemoteItem): String = withContext(Dispatchers.IO) {
        val mac = endpoint(macId) ?: throw notReachable()
        val (collection: Uri, folder) = when (item.kind) {
            "image" -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to "Pictures/Glimpse"
            "video" -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to "Movies/Glimpse"
            else -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to "Download/Glimpse"
        }
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, item.name)
            put(MediaStore.MediaColumns.MIME_TYPE, item.mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, folder)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values) ?: throw PeerException("save_failed", "The phone could not make the file.")
        try {
            resolver.openOutputStream(uri)!!.use { mac.client.download(mac.host, mac.port, item.id, it) }
            resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        folder
    }

    private fun notReachable() = PeerException("unreachable", "The Mac is not reachable.")
}
