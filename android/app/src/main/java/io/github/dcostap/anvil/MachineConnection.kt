package io.github.dcostap.anvil

import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

// An error reply of the Machine, or a connection fault. `offline`: the request was not sent. `disconnected`: its
// reply did not arrive, so the Machine can have done it. The other codes come from the server, such as
// `unauthorized`, `pairing_ended` or `forbidden`.
class MachineError(val code: String, message: String) : Exception(message)

// One connection to a Machine's server (`anvil serve`). `open` sends `hello`, then requests wait for their replies.
class MachineConnection private constructor(private val socket: Socket) : AutoCloseable {
    private val output = socket.getOutputStream()
    private val pending = ConcurrentHashMap<Int, CompletableDeferred<JSONObject>>()
    private val ids = AtomicInteger(0)

    // Completes when the connection ends.
    val closed = CompletableDeferred<Unit>()

    init {
        thread(name = "machine-reader", isDaemon = true) { read() }
    }

    // Sends one request and returns its `result`. A result that is not an object, such as `true`, gives an
    // empty object.
    suspend fun request(method: String, params: JSONObject = JSONObject()): JSONObject {
        val id = ids.incrementAndGet()
        val reply = CompletableDeferred<JSONObject>()
        pending[id] = reply
        val json = JSONObject().put("method", method).put("params", params).toString().toByteArray()
        try {
            withContext(Dispatchers.IO) {
                synchronized(output) {
                    output.write(MachineFrames.header(MachineFrames.REQUEST, id, json.size, 0) + json)
                    output.flush()
                }
            }
        } catch (e: IOException) {
            pending.remove(id)
            close()
            throw MachineError("offline", "The Machine is not connected")
        }
        // A reply can arrive before the reader saw the close. A close fails the requests that still wait.
        if (closed.isCompleted) pending.remove(id)?.completeExceptionally(disconnected())
        val body = reply.await()
        body.optJSONObject("error")?.let {
            throw MachineError(it.optString("code", "error"), it.optString("message", "The Machine refused the request"))
        }
        return body.optJSONObject("result") ?: JSONObject()
    }

    private fun read() {
        val buffer = ByteArray(64 * 1024)
        try {
            FrameDecoder(MAX_JSON, MAX_BYTES).use { decoder ->
                val input = socket.getInputStream()
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    decoder.feed(buffer, count)
                    while (true) {
                        val frame = decoder.next() ?: break
                        if (frame.type != MachineFrames.REPLY) throw IOException("The Machine sent a request")
                        pending.remove(frame.id)?.complete(JSONObject(String(frame.json)))
                    }
                }
            }
        } catch (e: Exception) {
            Log.d(TAG, "Machine connection ended: $e")
        }
        close()
    }

    override fun close() {
        try {
            socket.close()
        } catch (_: IOException) {
        }
        closed.complete(Unit)
        for (id in pending.keys.toList()) pending.remove(id)?.completeExceptionally(disconnected())
    }

    private fun disconnected() = MachineError("disconnected", "The Machine connection ended")

    companion object {
        const val PROTOCOL = 1
        private const val TAG = "AnvilMachine"
        private const val CONNECT_TIMEOUT_MS = 10_000
        private const val MAX_JSON = 1 shl 20
        private const val MAX_BYTES = 16 shl 20

        // Connects and logs in. The connect and the `hello` reply must finish in 10 seconds, because a forwarder,
        // such as Tailscale Serve, can accept a connection that no server answers. Returns the `hello` result.
        suspend fun open(host: String, port: Int, credentials: JSONObject): Pair<MachineConnection, JSONObject> {
            val connection = withContext(Dispatchers.IO) {
                val socket = Socket()
                try {
                    socket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
                } catch (e: IOException) {
                    socket.close()
                    throw MachineError("offline", "Cannot reach $host:$port")
                }
                socket.tcpNoDelay = true
                MachineConnection(socket)
            }
            try {
                val hello = withTimeout(CONNECT_TIMEOUT_MS.toLong()) {
                    connection.request("hello", JSONObject(credentials.toString()).put("protocol", PROTOCOL))
                }
                return connection to hello
            } catch (e: Throwable) {
                connection.close()
                if (e is kotlinx.coroutines.TimeoutCancellationException) {
                    throw MachineError("offline", "The Machine at $host:$port did not answer")
                }
                throw e
            }
        }
    }
}
