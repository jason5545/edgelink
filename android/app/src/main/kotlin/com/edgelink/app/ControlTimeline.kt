package com.edgelink.app

import android.os.SystemClock

object ControlTimeline {
    @Volatile
    private var lastControlAtNanos = 0L

    fun mark() {
        lastControlAtNanos = SystemClock.elapsedRealtimeNanos()
    }

    fun sinceLastControlMs(): Long {
        val last = lastControlAtNanos
        if (last == 0L) {
            return -1L
        }
        return (SystemClock.elapsedRealtimeNanos() - last) / 1_000_000L
    }
}
