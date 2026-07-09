package com.edgelink.app

import java.util.Base64

private const val COMMAND_RESULT_SEPARATOR = ":"

data class ShizukuCommandResult(
    val exitCode: Int,
    val stdout: String,
    val stderr: String
) {
    val success: Boolean
        get() = exitCode == 0

    fun encode(): String =
        listOf(exitCode.toString(), stdout.encodeBase64(), stderr.encodeBase64())
            .joinToString(COMMAND_RESULT_SEPARATOR)

    companion object {
        fun decode(value: String): ShizukuCommandResult {
            val parts = value.split(COMMAND_RESULT_SEPARATOR, limit = 3)
            if (parts.size != 3) {
                return ShizukuCommandResult(exitCode = 1, stdout = "", stderr = value)
            }
            return ShizukuCommandResult(
                exitCode = parts[0].toIntOrNull() ?: 1,
                stdout = parts[1].decodeBase64(),
                stderr = parts[2].decodeBase64()
            )
        }
    }
}

private fun String.encodeBase64(): String =
    Base64.getEncoder().encodeToString(toByteArray(Charsets.UTF_8))

private fun String.decodeBase64(): String =
    String(Base64.getDecoder().decode(this), Charsets.UTF_8)
