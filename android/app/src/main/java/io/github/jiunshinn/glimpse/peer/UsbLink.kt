package io.github.jiunshinn.glimpse.peer

import android.util.Log
import org.json.JSONObject
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

/**
 * The USB accessory link to a Mac (Android Open Accessory). The link only carries bytes: the Mac opens a stream
 * for each connection, and the phone connects the stream to its own HTTPS server on this device. So TLS,
 * the pinned certificates and the API are the same as on Wi-Fi.
 *
 * A frame is: stream id (4 bytes) · type (1 byte) · payload length (4 bytes) · payload. Stream 0 carries control
 * messages. The format must stay the same as `UsbLink.swift` on the Mac.
 */
class UsbLink(
    private val input: FileInputStream,
    private val output: FileOutputStream,
    private val serverPort: () -> Int,
    private val hello: JSONObject,
    private val onClose: () -> Unit,
) {
    private val streams = ConcurrentHashMap<Int, Socket>()
    @Volatile private var closed = false

    fun start() {
        send(0, HELLO, hello.toString().toByteArray(Charsets.UTF_8))
        thread(name = "usb-read") { readLoop() }
    }

    fun close() {
        if (closed) return
        closed = true
        streams.values.forEach { runCatching { it.close() } }
        streams.clear()
        runCatching { input.close() }
        runCatching { output.close() }
        onClose()
    }

    private fun readLoop() {
        // A USB read returns one transfer. The buffer must be at least as large as the Mac's largest write.
        val buffer = ByteArray(READ_SIZE)
        val pending = ByteBuffer.allocate(4 * READ_SIZE + HEADER)
        try {
            while (!closed) {
                val count = input.read(buffer)
                if (count < 0) break
                if (count == 0) continue
                ensureRoom(pending, count)
                pending.put(buffer, 0, count)
                pending.flip()
                while (pending.remaining() >= HEADER) {
                    pending.mark()
                    val stream = pending.int
                    val type = pending.get()
                    val length = pending.int
                    if (length < 0 || length > MAX_PAYLOAD) throw IOException("Bad frame length $length")
                    if (pending.remaining() < length) { pending.reset(); break }
                    val payload = ByteArray(length).also { pending.get(it) }
                    handle(stream, type, payload)
                }
                pending.compact()
            }
        } catch (e: IOException) {
            Log.i(TAG, "USB link closed: ${e.message}")
        }
        close()
    }

    private fun ensureRoom(buffer: ByteBuffer, count: Int) {
        if (buffer.remaining() < count) throw IOException("Frame buffer overflow")
    }

    private fun handle(stream: Int, type: Byte, payload: ByteArray) {
        when (type) {
            OPEN -> open(stream)
            DATA -> {
                val socket = streams[stream] ?: return
                try { socket.getOutputStream().apply { write(payload); flush() } } catch (_: IOException) { closeStream(stream, notify = true) }
            }
            CLOSE -> closeStream(stream, notify = false)
            NOOP, HELLO -> Unit
        }
    }

    /**
     * The Mac opened a connection: connect it to the phone's server and copy its replies back.
     * The connection is made here, on the read thread, so the stream's first data never arrives before it.
     */
    private fun open(stream: Int) {
        val socket = try {
            Socket(InetAddress.getLoopbackAddress(), serverPort()).apply { tcpNoDelay = true }
        } catch (e: IOException) {
            send(stream, CLOSE, ByteArray(0))
            return
        }
        streams[stream] = socket
        thread(name = "usb-stream-$stream") { pump(stream, socket.getInputStream()) }
    }

    private fun pump(stream: Int, from: InputStream) {
        val buffer = ByteArray(MAX_PAYLOAD)
        try {
            while (!closed) {
                val count = from.read(buffer)
                if (count < 0) break
                if (count > 0) send(stream, DATA, buffer.copyOf(count))
            }
        } catch (_: IOException) {
        }
        closeStream(stream, notify = true)
    }

    private fun closeStream(stream: Int, notify: Boolean) {
        val socket = streams.remove(stream) ?: return
        runCatching { socket.close() }
        if (notify) send(stream, CLOSE, ByteArray(0))
    }

    @Synchronized
    private fun send(stream: Int, type: Byte, payload: ByteArray) {
        if (closed) return
        val frame = ByteBuffer.allocate(HEADER + payload.size + HEADER)
        frame.putInt(stream).put(type).putInt(payload.size).put(payload)
        // A write that fills whole USB packets would wait on the Mac for more bytes. A short padding frame ends it.
        if ((HEADER + payload.size) % PACKET == 0) frame.putInt(0).put(NOOP).putInt(0)
        try {
            output.write(frame.array(), 0, frame.position())
        } catch (e: IOException) {
            Log.i(TAG, "USB write failed: ${e.message}")
            thread { close() }
        }
    }

    companion object {
        private const val TAG = "UsbLink"
        const val HEADER = 9
        const val READ_SIZE = 16 * 1024
        const val MAX_PAYLOAD = READ_SIZE - 2 * HEADER
        const val PACKET = 512
        const val NOOP: Byte = 0
        const val OPEN: Byte = 1
        const val DATA: Byte = 2
        const val CLOSE: Byte = 3
        const val HELLO: Byte = 16
    }
}
