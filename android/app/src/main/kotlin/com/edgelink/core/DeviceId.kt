package com.edgelink.core

object DeviceId {
    private val pattern = Regex("[1-9][0-9]{8}")

    fun isValid(value: String): Boolean = pattern.matches(value)

    fun display(value: String): String =
        if (value.length == 9) "${value.substring(0, 3)} ${value.substring(3, 6)} ${value.substring(6, 9)}" else value
}
