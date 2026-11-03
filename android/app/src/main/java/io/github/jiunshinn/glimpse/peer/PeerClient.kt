package io.github.jiunshinn.glimpse.peer

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.net.NoRouteToHostException
import java.net.Socket
import java.security.Principal
import java.security.PrivateKey
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509TrustManager

/** What `GET /v1/info` tells about a Mac. */
data class PeerInfo(
    val id: String,
    val name: String,
    val platform: String,
    val protocols: List<Int>,
    val paired: Boolean,
) {
    companion object {
        fun fromJson(json: JSONObject): PeerInfo {
            val protocols = json.optJSONArray("protocol")
            return PeerInfo(
                id = json.getString("id"),
                name = json.getString("name"),
                platform = json.optString("platform"),
                protocols = List(protocols?.length() ?: 0) { protocols!!.getInt(it) },
                paired = json.optBoolean("paired"),
            )
        }
    }
}

/** A shared folder on the Mac. */
data class RemoteAlbum(val id: String, val name: String, val count: Int)

/** A file or a subfolder in a shared folder on the Mac. */
data class RemoteItem(
    val id: String,
    val name: String,
    val kind: String,
    val mime: String,
    val size: Long,
    /** For a folder: its path inside the shared folder. */
    val path: String,
    val count: Int,
) {
    val isFolder: Boolean get() = kind == "folder"
}

/** An API error with the `error` code of the peer protocol, or a network failure. */
class PeerException(val code: String, message: String, cause: Throwable? = null) : IOException(message, cause)

/**
 * HTTPS client for one Mac. TLS trusts exactly one certificate: the one whose fingerprint was in the QR code.
 * The phone shows its own Keystore certificate, so the Mac knows which phone asks.
 */
class PeerClient(
    identity: DeviceIdentity,
    private val fingerprint: String,
) {
    private val http: OkHttpClient = run {
        val trust = PinnedTrustManager(fingerprint)
        val context = SSLContext.getInstance("TLS").apply {
            init(arrayOf(DeviceKeyManager(identity.privateKey, identity.certificate)), arrayOf(trust), null)
        }
        OkHttpClient.Builder()
            .sslSocketFactory(context.socketFactory, trust)
            // The pinned certificate proves the Mac. A LAN address has no host name to check.
            .hostnameVerifier { _, _ -> true }
            .connectTimeout(4, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .build()
    }

    suspend fun info(host: String, port: Int): PeerInfo {
        return PeerInfo.fromJson(call(Request.Builder().url(url(host, port, "/v1/info")).build()))
    }

    suspend fun pair(host: String, port: Int, code: String, phoneName: String) {
        val body = JSONObject()
            .put("code", code)
            .put("name", phoneName)
            .put("platform", "android")
            .toString()
            .toRequestBody("application/json".toMediaType())
        call(Request.Builder().url(url(host, port, "/v1/pair")).post(body).build())
    }

    suspend fun albums(host: String, port: Int): List<RemoteAlbum> {
        val array = call(Request.Builder().url(url(host, port, "/v1/albums")).build()).optJSONArray("albums")
        return List(array?.length() ?: 0) { index ->
            val album = array!!.getJSONObject(index)
            RemoteAlbum(album.getString("id"), album.getString("name"), album.optInt("count"))
        }
    }

    suspend fun items(host: String, port: Int, albumId: String, path: String): List<RemoteItem> {
        val query = "?path=" + java.net.URLEncoder.encode(path, "UTF-8").replace("+", "%20")
        val array = call(Request.Builder().url(url(host, port, "/v1/albums/$albumId/items$query")).build()).optJSONArray("items")
        return List(array?.length() ?: 0) { index ->
            val item = array!!.getJSONObject(index)
            RemoteItem(
                id = item.optString("id"),
                name = item.getString("name"),
                kind = item.getString("kind"),
                mime = item.optString("mime", "application/octet-stream"),
                size = item.optLong("size"),
                path = item.optString("path"),
                count = item.optInt("count"),
            )
        }
    }

    /** The bytes of a small response, such as a JPEG preview. Null when the Mac has no preview. */
    suspend fun bytes(host: String, port: Int, path: String): ByteArray? = withContext(Dispatchers.IO) {
        runCatching {
            http.newCall(Request.Builder().url(url(host, port, path)).build()).execute().use { response ->
                if (response.isSuccessful) response.body?.bytes() else null
            }
        }.getOrNull()
    }

    /** Copies a file from the Mac into [sink], in chunks. */
    suspend fun download(host: String, port: Int, itemId: String, sink: java.io.OutputStream) = withContext(Dispatchers.IO) {
        http.newCall(Request.Builder().url(url(host, port, "/v1/items/$itemId/content")).build()).execute().use { response ->
            if (!response.isSuccessful) throw PeerException("http_${response.code}", "The Mac answered ${response.code}.")
            response.body!!.byteStream().use { it.copyTo(sink, 64 * 1024) }
        }
    }

    /** Tells the Mac where the phone's own server listens. The Mac takes the address from the connection. */
    suspend fun hello(host: String, port: Int, serverPort: Int, phoneName: String) {
        val body = JSONObject().put("port", serverPort).put("name", phoneName).toString()
            .toRequestBody("application/json".toMediaType())
        call(Request.Builder().url(url(host, port, "/v1/hello")).post(body).build())
    }

    private fun url(host: String, port: Int, path: String): String {
        val literal = if (host.contains(':')) "[$host]" else host  // IPv6
        return "https://$literal:$port$path"
    }

    private suspend fun call(request: Request): JSONObject = withContext(Dispatchers.IO) {
        try {
            http.newCall(request).execute().use { response ->
                val text = response.body?.string().orEmpty()
                val json = runCatching { JSONObject(text) }.getOrElse { JSONObject() }
                if (!response.isSuccessful) {
                    throw PeerException(json.optString("error", "http_${response.code}"), json.optString("message", text))
                }
                json
            }
        } catch (e: PeerException) {
            throw e
        } catch (e: SSLHandshakeException) {
            throw PeerException("wrong_mac", "The Mac's certificate does not match the paired Mac.", e)
        } catch (e: IOException) {
            // OkHttp wraps the socket error. "No route to host" means that nothing on this network answers at the
            // address: the Mac sleeps, or the router stops Wi-Fi devices from talking to each other.
            val noRoute = generateSequence<Throwable>(e) { it.cause }.any {
                it is NoRouteToHostException || it.message.orEmpty().contains("EHOSTUNREACH")
            }
            throw PeerException(if (noRoute) "no_route" else "unreachable", e.message ?: "The Mac is not reachable.", e)
        }
    }
}

private class PinnedTrustManager(private val fingerprint: String) : X509TrustManager {
    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        val leaf = chain?.firstOrNull() ?: throw CertificateException("No server certificate")
        if (DeviceIdentity.fingerprint(leaf) != fingerprint) throw CertificateException("Certificate pin mismatch")
    }

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) =
        throw CertificateException("This client accepts no clients")

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

/** Offers the Keystore key as the client certificate (phone to Mac) and as the server certificate (Mac to phone). */
internal class DeviceKeyManager(
    private val key: PrivateKey,
    private val certificate: X509Certificate,
) : X509ExtendedKeyManager() {
    override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf(ALIAS)
    override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = ALIAS
    override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?) = ALIAS
    override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf(ALIAS)
    override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?) = ALIAS
    override fun chooseEngineServerAlias(keyType: String?, issuers: Array<out Principal>?, engine: SSLEngine?) = ALIAS
    override fun getCertificateChain(alias: String?) = arrayOf(certificate)
    override fun getPrivateKey(alias: String?) = key

    private companion object {
        const val ALIAS = "glimpse-device"
    }
}
