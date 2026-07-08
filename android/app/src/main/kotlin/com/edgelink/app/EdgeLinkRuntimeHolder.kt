package com.edgelink.app

import android.content.Context

object EdgeLinkRuntimeHolder {
    @Volatile
    private var controller: EdgeLinkController? = null

    fun getOrCreate(context: Context): EdgeLinkController =
        controller ?: synchronized(this) {
            controller ?: EdgeLinkController(context.applicationContext).also { controller = it }
        }

    fun existing(): EdgeLinkController? = controller

    fun close(controllerToClose: EdgeLinkController) {
        synchronized(this) {
            if (controller === controllerToClose) {
                controllerToClose.close()
                controller = null
            }
        }
    }
}
