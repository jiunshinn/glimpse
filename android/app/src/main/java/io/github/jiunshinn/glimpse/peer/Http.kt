package io.github.jiunshinn.glimpse.peer

import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.URLDecoder

/** A small HTTP/1.1 subset for the peer API, the same subset as the Mac server: `Content-Length` bodies only. */
class HttpRequest(
    val method: String,
    val path: String,
    val query: Map<String, String>,
    /** Header names in lowercase. */
    val headers: Map<String, String>,
    val body: ByteArray,
) {
    val keepAlive: Boolean get() = headers["connection"]?.lowercase() != "close"

    val json: JSONObject? get() = runCatching { JSONObject(body.toString(Charsets.UTF_8)) }.getOrNull()

    companion object {
        private const val MAX_HEADER_BYTES = 16 * 1024
        private const val MAX_BODY_BYTES = 1024 * 1024

        /** Reads one request. Returns null when the client closed the connection. */
        fun read(input: BufferedInputStream): HttpRequest? {
            val head = readHead(input) ?: return null
            val lines = head.split("\r\n")
            val parts = lines.first().split(" ")
            if (parts.size != 3 || !parts[2].startsWith("HTTP/1.")) throw IOException("Bad request line")
            val headers = lines.drop(1).filter { it.isNotEmpty() }.associate { line ->
                val colon = line.indexOf(':')
                if (colon <= 0) throw IOException("Bad header")
                line.substring(0, colon).trim().lowercase() to line.substring(colon + 1).trim()
            }
            val length = headers["content-length"]?.toIntOrNull() ?: 0
            if (length !in 0..MAX_BODY_BYTES || headers.containsKey("transfer-encoding")) throw IOException("Bad body")
            val body = ByteArray(length)
            var read = 0
            while (read < length) {
                val n = input.read(body, read, length - read)
                if (n < 0) throw IOException("Body ended early")
                read += n
            }
            val target = parts[1]
            val question = target.indexOf('?')
            val path = URLDecoder.decode(if (question < 0) target else target.substring(0, question), "UTF-8")
            val query = if (question < 0) emptyMap() else target.substring(question + 1).split("&").mapNotNull {
                val pair = it.split("=", limit = 2)
                if (pair[0].isEmpty()) null
                else URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair.getOrElse(1) { "" }, "UTF-8")
            }.toMap()
            return HttpRequest(parts[0], path, query, headers, body)
        }

        private fun readHead(input: BufferedInputStream): String? {
            val bytes = java.io.ByteArrayOutputStream()
            var last4 = 0
            while (true) {
                val b = input.read()
                if (b < 0) return if (bytes.size() == 0) null else throw IOException("Headers ended early")
                bytes.write(b)
                last4 = (last4 shl 8) or b
                if (last4 == 0x0D0A0D0A) break
                if (bytes.size() > MAX_HEADER_BYTES) throw IOException("Headers too large")
            }
            return bytes.toString("UTF-8").removeSuffix("\r\n\r\n")
        }
    }
}

/** A response. The body is a stream, so a large file never sits in memory. */
class HttpResponse(
    val status: Int,
    val headers: Map<String, String> = emptyMap(),
    val body: InputStream = ByteArrayInputStream(ByteArray(0)),
    val length: Long = 0,
) {
    fun write(output: OutputStream, keepAlive: Boolean) {
        val head = StringBuilder("HTTP/1.1 $status ${reason(status)}\r\n")
        (headers + mapOf("Content-Length" to length.toString(), "Connection" to if (keepAlive) "keep-alive" else "close"))
            .forEach { (name, value) -> head.append(name).append(": ").append(value).append("\r\n") }
        head.append("\r\n")
        output.write(head.toString().toByteArray(Charsets.UTF_8))
        body.use { input ->
            val buffer = ByteArray(64 * 1024)
            var remaining = length
            while (remaining > 0) {
                val n = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                if (n < 0) throw IOException("File ended early")
                output.write(buffer, 0, n)
                remaining -= n
            }
        }
        output.flush()
    }

    companion object {
        fun json(status: Int, json: JSONObject): HttpResponse {
            val bytes = json.toString().toByteArray(Charsets.UTF_8)
            return HttpResponse(status, mapOf("Content-Type" to "application/json; charset=utf-8"), ByteArrayInputStream(bytes), bytes.size.toLong())
        }

        /** The error shape of the peer API: `{"error": "<code>", "message": "<text for logs>"}`. */
        fun error(status: Int, code: String, message: String) =
            json(status, JSONObject().put("error", code).put("message", message))

        private fun reason(status: Int) = when (status) {
            200 -> "OK"
            206 -> "Partial Content"
            400 -> "Bad Request"
            401 -> "Unauthorized"
            403 -> "Forbidden"
            404 -> "Not Found"
            405 -> "Method Not Allowed"
            416 -> "Range Not Satisfiable"
            else -> "Error"
        }
    }
}
