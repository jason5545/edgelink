package com.edgelink.app

import com.edgelink.core.ClipboardBlobTransfer
import org.junit.Assert.assertEquals
import org.junit.Test

// Image clipboards are content-hashed (sha256 of the blob bytes) so an image
// applied from the peer polls back with the same hash and is not re-broadcast.
class ClipboardImageHashTest {
    @Test
    fun imageHashPrefersBlobBytes() {
        val bytes = byteArrayOf(1, 2, 3, 4)
        assertEquals(
            ClipboardBlobTransfer.sha256Hex(bytes),
            AndroidClipboardSync.imageContentHash(bytes, "dGh1bWI=")
        )
    }

    @Test
    fun imageHashFallsBackToThumbnail() {
        assertEquals(
            AndroidClipboardSync.hash("\u0001dGh1bWI="),
            AndroidClipboardSync.imageContentHash(null, "dGh1bWI=")
        )
    }

    @Test
    fun appliedImageHashMatchesRepollHash() {
        // applyRemoteImage stores sha256(data); the next poll reads the same
        // bytes back from the FileProvider URI, so the hashes must agree.
        val bytes = "fake-png".toByteArray()
        assertEquals(
            ClipboardBlobTransfer.sha256Hex(bytes),
            AndroidClipboardSync.imageContentHash(bytes, null)
        )
    }
}
