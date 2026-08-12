package com.edgelink.app

import android.os.Build

object AndroidDeviceName {
    fun resolve(): String = compose(
        marketName = readMarketName(),
        manufacturer = Build.MANUFACTURER,
        model = Build.MODEL
    )

    internal fun compose(marketName: String, manufacturer: String, model: String): String {
        val market = marketName.trim()
        if (market.isNotEmpty()) {
            return market
        }
        return listOf(manufacturer, model)
            .filter { it.isNotBlank() }
            .joinToString(" ")
            .ifBlank { "Android" }
    }

    private fun readMarketName(): String =
        runCatching {
            val process = ProcessBuilder("getprop", "ro.product.marketname").start()
            process.inputStream.bufferedReader().readLine().orEmpty().trim()
        }.getOrDefault("")
}
