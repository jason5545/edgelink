package com.edgelink.transport

import okhttp3.OkHttpClient
import okhttp3.Request

class RelayTransport(
    private val client: OkHttpClient = OkHttpClient()
) {
    fun request(url: String): Request =
        Request.Builder()
            .url(url)
            .build()
}
