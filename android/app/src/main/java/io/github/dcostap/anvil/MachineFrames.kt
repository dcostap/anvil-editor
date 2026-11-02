package io.github.dcostap.anvil

// The Machine protocol's frames, through the desktop's codec (`src/machine_frame.c`). A frame is a 13-byte header,
// a JSON body, then raw bytes.
object MachineFrames {
    const val REQUEST = 1
    const val REPLY = 2

    class Frame(val type: Int, val id: Int, val json: ByteArray, val bytes: ByteArray)

    init {
        System.loadLibrary("anvil_companion")
    }

    @JvmStatic external fun header(type: Int, id: Int, jsonLength: Int, bytesLength: Int): ByteArray
    @JvmStatic external fun newDecoder(maxJson: Int, maxBytes: Int): Long
    @JvmStatic external fun freeDecoder(handle: Long)
    @JvmStatic external fun feed(handle: Long, data: ByteArray, length: Int): Boolean
    @JvmStatic external fun next(handle: Long): Frame?
}

// Splits received data into frames. Each limit applies before the body arrives.
class FrameDecoder(maxJson: Int, maxBytes: Int) : AutoCloseable {
    private var handle = MachineFrames.newDecoder(maxJson, maxBytes)

    init {
        check(handle != 0L) { "No memory for the frame decoder" }
    }

    fun feed(data: ByteArray, length: Int) {
        check(MachineFrames.feed(handle, data, length)) { "No memory for the received frames" }
    }

    // The next whole frame, or null when more data must come. Throws an IOException for an invalid header.
    fun next(): MachineFrames.Frame? = MachineFrames.next(handle)

    override fun close() {
        if (handle != 0L) MachineFrames.freeDecoder(handle)
        handle = 0L
    }
}
