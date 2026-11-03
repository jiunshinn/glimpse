package io.github.jiunshinn.glimpse.peer

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.media.ThumbnailUtils
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.util.Size
import android.webkit.MimeTypeMap
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.util.Base64

/** The kinds of files Glimpse shows, as in the Mac app. */
enum class ItemKind(val wire: String) { Folder("folder"), Image("image"), Video("video"), Document("document"), Other("other") }

/** A file the Mac can download: its stream, its size and its type. */
class ItemContent(val open: () -> InputStream, val size: Long, val mime: String, val name: String)

/**
 * What the phone shares with a paired Mac:
 * - Albums: photos and videos from MediaStore (the photos permission).
 * - Files: the folders of the shared storage (the "All files access" permission).
 *
 * Item IDs are opaque to the Mac: `m<MediaStore id>` for a photo or video, `f<base64url path>` for a file.
 */
class PhoneLibrary(private val context: Context) {
    private val resolver: ContentResolver = context.contentResolver
    private val root: File = Environment.getExternalStorageDirectory()
    private val mediaCollection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
    private val visualMedia = "(${MediaStore.Files.FileColumns.MEDIA_TYPE}=${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE} OR " +
        "${MediaStore.Files.FileColumns.MEDIA_TYPE}=${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO})"

    val canReadFiles: Boolean get() = Environment.isExternalStorageManager()

    // MARK: Albums

    fun albums(): JSONArray {
        data class Album(val id: String, val name: String, var count: Int, val cover: Long)
        val albums = linkedMapOf<String, Album>()
        val columns = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.MediaColumns.BUCKET_ID,
            MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
        )
        resolver.query(mediaCollection, columns, visualMedia, null, "${MediaStore.MediaColumns.DATE_MODIFIED} DESC")?.use { cursor ->
            while (cursor.moveToNext()) {
                val bucket = cursor.getString(1) ?: continue
                val album = albums.getOrPut(bucket) { Album(bucket, cursor.getString(2) ?: "Photos", 0, cursor.getLong(0)) }
                album.count++
            }
        }
        // The camera album first, then by size, as in the phone's own gallery.
        val sorted = albums.values.sortedWith(compareByDescending<Album> { it.name.equals("Camera", true) }.thenByDescending { it.count })
        return JSONArray().apply {
            sorted.forEach { put(JSONObject().put("id", "b${it.id}").put("name", it.name).put("count", it.count).put("coverItemId", "m${it.cover}")) }
        }
    }

    /** One page of an album, newest first. [cursor] is the offset of the page. */
    fun albumItems(albumId: String, cursor: Int, limit: Int): JSONObject {
        val bucket = albumId.removePrefix("b")
        val columns = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT,
            MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.DATE_MODIFIED,
        )
        val args = Bundle().apply {
            putString(ContentResolver.QUERY_ARG_SQL_SELECTION, "$visualMedia AND ${MediaStore.MediaColumns.BUCKET_ID}=?")
            putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, arrayOf(bucket))
            putStringArray(ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(MediaStore.MediaColumns.DATE_MODIFIED))
            putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
            putInt(ContentResolver.QUERY_ARG_LIMIT, limit + 1)  // One more tells whether a next page exists.
            putInt(ContentResolver.QUERY_ARG_OFFSET, cursor)
        }
        val items = JSONArray()
        var more = false
        resolver.query(mediaCollection, columns, args, null)?.use { c ->
            while (c.moveToNext()) {
                if (items.length() == limit) { more = true; break }
                val video = c.getInt(2) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                val taken = c.getLong(7)
                items.put(JSONObject()
                    .put("id", "m${c.getLong(0)}")
                    .put("name", c.getString(1) ?: "")
                    .put("kind", if (video) "video" else "image")
                    .put("mime", c.getString(3) ?: "")
                    .put("size", c.getLong(4))
                    .put("width", c.getInt(5))
                    .put("height", c.getInt(6))
                    .put("modified", c.getLong(8))
                    .apply { if (taken > 0) put("taken", taken / 1000) })
            }
        }
        return JSONObject().put("items", items).apply { if (more) put("next", (cursor + limit).toString()) }
    }

    // MARK: Files

    /** The entries of a folder in shared storage. [path] is relative to the storage root ("" = the root). */
    fun folder(path: String): JSONObject? {
        val folder = resolve(path) ?: return null
        if (!folder.isDirectory) return null
        val entries = folder.listFiles().orEmpty()
            .filter { !it.name.startsWith(".") }
            .sortedWith(compareByDescending<File> { it.isDirectory }.thenBy { it.name.lowercase() })
        val items = JSONArray()
        entries.forEach { file ->
            val relative = file.relativeTo(root).path
            val kind = kind(file)
            items.put(JSONObject()
                .put("id", "f" + encode(relative))
                .put("name", file.name)
                .put("kind", kind.wire)
                .put("path", relative)
                .put("modified", file.lastModified() / 1000)
                .apply {
                    if (kind == ItemKind.Folder) put("count", file.list()?.count { !it.startsWith(".") } ?: 0)
                    else put("size", file.length()).put("mime", mime(file))
                })
        }
        return JSONObject().put("path", folder.relativeTo(root).path).put("items", items)
    }

    // MARK: Items

    fun thumbnail(itemId: String, size: Int): ByteArray? {
        val bitmap: Bitmap = when {
            itemId.startsWith("m") -> {
                val uri = mediaUri(itemId) ?: return null
                runCatching { resolver.loadThumbnail(uri, Size(size, size), null) }.getOrNull()
            }
            itemId.startsWith("f") -> {
                val file = fileFor(itemId) ?: return null
                runCatching {
                    when (kind(file)) {
                        ItemKind.Image -> ThumbnailUtils.createImageThumbnail(file, Size(size, size), null)
                        ItemKind.Video -> ThumbnailUtils.createVideoThumbnail(file, Size(size, size), null)
                        else -> null
                    }
                }.getOrNull()
            }
            else -> null
        } ?: return null
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 82, it) }.toByteArray()
    }

    fun content(itemId: String): ItemContent? = when {
        itemId.startsWith("m") -> {
            val uri = mediaUri(itemId)
            uri?.let {
                val columns = arrayOf(MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.MIME_TYPE, MediaStore.MediaColumns.DISPLAY_NAME)
                resolver.query(it, columns, null, null, null)?.use { c ->
                    if (!c.moveToFirst()) null
                    else ItemContent({ resolver.openInputStream(uri)!! }, c.getLong(0), c.getString(1) ?: "application/octet-stream", c.getString(2) ?: "file")
                }
            }
        }
        itemId.startsWith("f") -> fileFor(itemId)?.takeIf { it.isFile }?.let { file ->
            ItemContent({ FileInputStream(file) }, file.length(), mime(file), file.name)
        }
        else -> null
    }

    // MARK: Helpers

    private fun mediaUri(itemId: String) = itemId.removePrefix("m").toLongOrNull()?.let { ContentUris.withAppendedId(mediaCollection, it) }

    private fun fileFor(itemId: String): File? =
        runCatching { String(Base64.getUrlDecoder().decode(itemId.removePrefix("f")), Charsets.UTF_8) }.getOrNull()?.let(::resolve)

    /** A path inside shared storage, or null when it leaves the storage root (`..`, a symbolic link). */
    private fun resolve(relative: String): File? {
        if (!canReadFiles) return null
        val base = root.canonicalFile
        val file = File(base, relative).canonicalFile
        return if (file == base || file.path.startsWith(base.path + File.separator)) file else null
    }

    private fun encode(path: String) = Base64.getUrlEncoder().withoutPadding().encodeToString(path.toByteArray(Charsets.UTF_8))

    private fun mime(file: File): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase()) ?: "application/octet-stream"

    private fun kind(file: File): ItemKind {
        if (file.isDirectory) return ItemKind.Folder
        val mime = mime(file)
        return when {
            mime.startsWith("image/") -> ItemKind.Image
            mime.startsWith("video/") -> ItemKind.Video
            mime == "application/pdf" || mime.startsWith("text/") || mime.contains("document") ||
                mime.contains("sheet") || mime.contains("presentation") || mime.contains("msword") -> ItemKind.Document
            else -> ItemKind.Other
        }
    }
}
