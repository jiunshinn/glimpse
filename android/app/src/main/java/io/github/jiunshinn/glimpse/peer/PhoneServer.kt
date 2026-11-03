package io.github.jiunshinn.glimpse.peer

import android.os.Build
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import java.io.IOException
import java.security.cert.X509Certificate
import java.util.concurrent.Executors
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

/**
 * HTTPS server of the phone, with the same API as the Mac (protocol/openapi.yaml).
 * TLS requires a client certificate. Only a Mac in [PairedMacs] gets past `/v1/info`.
 */
class PhoneServer(
    identity: DeviceIdentity,
    private val macs: PairedMacs,
    private val library: PhoneLibrary,
    private val phoneName: String,
    private val appVersion: String,
) {
    private val context = SSLContext.getInstance("TLS").apply {
        init(arrayOf(DeviceKeyManager(identity.privateKey, identity.certificate)), arrayOf(AnyClientTrustManager), null)
    }
    private val deviceId = identity.fingerprint.take(16)
    private val pool = Executors.newCachedThreadPool()
    private var socket: SSLServerSocket? = null

    val port: Int get() = socket?.localPort ?: 0

    /** Listens on [PREFERRED_PORT], or on any free port when it is taken. */
    fun start() {
        val server = runCatching { context.serverSocketFactory.createServerSocket(PREFERRED_PORT) }
            .getOrElse { context.serverSocketFactory.createServerSocket(0) } as SSLServerSocket
        server.needClientAuth = true
        socket = server
        pool.execute {
            while (!server.isClosed) {
                val client = runCatching { server.accept() }.getOrNull() ?: break
                pool.execute { serve(client as SSLSocket) }
            }
        }
    }

    fun stop() {
        runCatching { socket?.close() }
        socket = null
        pool.shutdownNow()
    }

    private fun serve(client: SSLSocket) {
        client.use {
            try {
                client.soTimeout = 60_000
                client.startHandshake()
                val certificate = client.session.peerCertificates.firstOrNull() as? X509Certificate ?: return
                val fingerprint = DeviceIdentity.fingerprint(certificate)
                val input = BufferedInputStream(client.inputStream)
                val output = client.outputStream.buffered(64 * 1024)
                while (true) {
                    val request = HttpRequest.read(input) ?: break
                    val response = runCatching { handle(request, fingerprint) }
                        .getOrElse { HttpResponse.error(500, "internal", it.message ?: "Error") }
                    response.write(output, request.keepAlive)
                    if (!request.keepAlive) break
                }
            } catch (e: IOException) {
                Log.d(TAG, "Connection closed: ${e.message}")
            }
        }
    }

    private fun handle(request: HttpRequest, fingerprint: String): HttpResponse {
        val paired = macs.all().any { it.fingerprint == fingerprint }
        if (request.method == "GET" && request.path == "/v1/info") {
            return HttpResponse.json(200, JSONObject()
                .put("id", deviceId)
                .put("name", phoneName)
                .put("platform", "android")
                .put("appVersion", appVersion)
                .put("protocol", JSONArray().put(1))
                .put("capabilities", JSONArray().put("albums").put("files"))
                .put("paired", paired)
                .put("model", Build.MODEL))
        }
        if (!paired) return HttpResponse.error(401, "not_paired", "Pair this Mac with the phone first.")
        if (request.method != "GET") return HttpResponse.error(405, "method_not_allowed", "Only GET is served.")
        val path = request.path
        return when {
            path == "/v1/albums" -> HttpResponse.json(200, JSONObject().put("albums", library.albums()))
            path.startsWith("/v1/albums/") && path.endsWith("/items") -> {
                val album = path.removePrefix("/v1/albums/").removeSuffix("/items")
                val cursor = request.query["cursor"]?.toIntOrNull() ?: 0
                val limit = (request.query["limit"]?.toIntOrNull() ?: 500).coerceIn(1, 2000)
                HttpResponse.json(200, library.albumItems(album, cursor, limit))
            }
            path == "/v1/files" -> {
                if (!library.canReadFiles) {
                    HttpResponse.error(403, "files_not_allowed", "Allow All files access for Glimpse on the phone.")
                } else {
                    library.folder(request.query["path"].orEmpty())?.let { HttpResponse.json(200, it) }
                        ?: HttpResponse.error(404, "not_found", "No such folder.")
                }
            }
            path.startsWith("/v1/items/") && path.endsWith("/thumbnail") -> {
                val id = path.removePrefix("/v1/items/").removeSuffix("/thumbnail")
                val size = (request.query["size"]?.toIntOrNull() ?: 256).coerceIn(32, 2048)
                library.thumbnail(id, size)?.let {
                    HttpResponse(200, mapOf("Content-Type" to "image/jpeg"), ByteArrayInputStream(it), it.size.toLong())
                } ?: HttpResponse.error(404, "no_thumbnail", "No thumbnail for this item.")
            }
            path.startsWith("/v1/items/") && path.endsWith("/content") -> {
                val id = path.removePrefix("/v1/items/").removeSuffix("/content")
                val content = library.content(id) ?: return HttpResponse.error(404, "not_found", "No such item.")
                contentResponse(content, request.headers["range"])
            }
            else -> HttpResponse.error(404, "not_found", "No endpoint ${request.method} $path.")
        }
    }

    /** The whole file, or one byte range of it (`Range: bytes=a-b`) for video seeking. */
    private fun contentResponse(content: ItemContent, range: String?): HttpResponse {
        val headers = mapOf("Content-Type" to content.mime, "Accept-Ranges" to "bytes")
        val match = range?.let { Regex("""bytes=(\d*)-(\d*)""").matchEntire(it.trim()) }
            ?: return HttpResponse(200, headers, content.open(), content.size)
        val (from, to) = match.destructured
        val start = from.toLongOrNull() ?: (content.size - (to.toLongOrNull() ?: 0))
        val end = if (from.isEmpty()) content.size - 1 else (to.toLongOrNull() ?: (content.size - 1)).coerceAtMost(content.size - 1)
        if (start < 0 || start > end) {
            return HttpResponse(416, mapOf("Content-Range" to "bytes */${content.size}"))
        }
        val stream = content.open().apply { skipFully(start) }
        return HttpResponse(206, headers + ("Content-Range" to "bytes $start-$end/${content.size}"), stream, end - start + 1)
    }

    private fun java.io.InputStream.skipFully(count: Long) {
        var left = count
        while (left > 0) {
            val skipped = skip(left)
            if (skipped <= 0) { if (read() < 0) throw IOException("Range past the end"); left-- } else left -= skipped
        }
    }

    companion object {
        private const val TAG = "PhoneServer"
        const val PREFERRED_PORT = 53_818
    }
}

/** Client certificates are self-signed. The server decides per request by fingerprint, not by a CA. */
private object AnyClientTrustManager : X509TrustManager {
    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        if (chain.isNullOrEmpty()) throw java.security.cert.CertificateException("No client certificate")
    }

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) =
        throw java.security.cert.CertificateException("This server trusts no servers")

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}
