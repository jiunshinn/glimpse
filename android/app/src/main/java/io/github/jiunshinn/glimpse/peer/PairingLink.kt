package io.github.jiunshinn.glimpse.peer

import java.net.URI
import java.net.URLDecoder

/**
 * The content of the QR code that Glimpse on the Mac shows:
 * `glimpse://pair?h=<ip>&port=<port>&fp=<certificate fingerprint>&code=<one-time code>`.
 */
data class PairingLink(
    val host: String,
    val port: Int,
    val fingerprint: String,
    val code: String,
) {
    companion object {
        fun parse(text: String): PairingLink? {
            val uri = runCatching { URI(text.trim()) }.getOrNull() ?: return null
            if (uri.scheme != "glimpse" || uri.host != "pair") return null
            val query = uri.rawQuery?.split("&").orEmpty().mapNotNull { pair ->
                val parts = pair.split("=", limit = 2)
                if (parts.size != 2) return@mapNotNull null
                URLDecoder.decode(parts[0], "UTF-8") to URLDecoder.decode(parts[1], "UTF-8")
            }.toMap()
            val host = query["h"]?.takeIf { it.isNotBlank() } ?: return null
            val port = query["port"]?.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            val fingerprint = query["fp"]?.takeIf { it.length == 43 } ?: return null
            val code = query["code"]?.takeIf { it.isNotBlank() } ?: return null
            return PairingLink(host, port, fingerprint, code)
        }
    }
}
