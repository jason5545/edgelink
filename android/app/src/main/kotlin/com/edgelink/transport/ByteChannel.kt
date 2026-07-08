package com.edgelink.transport

interface ByteChannel {
    suspend fun send(bytes: ByteArray)
    suspend fun receive(): ByteArray?
    fun close() = Unit
}
