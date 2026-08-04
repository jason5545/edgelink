package com.edgelink.transport

import java.io.OutputStream

internal object LanFraming {
    fun writeFrame(output: OutputStream, bytes: ByteArray) {
        output.write(bytes.size shr 24 and 0xFF)
        output.write(bytes.size shr 16 and 0xFF)
        output.write(bytes.size shr 8 and 0xFF)
        output.write(bytes.size and 0xFF)
        output.write(bytes)
        output.flush()
    }
}
