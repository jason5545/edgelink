package com.edgelink.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import com.edgelink.ui.EdgeLinkApp

class MainActivity : ComponentActivity() {
    private lateinit var controller: EdgeLinkController

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        controller = EdgeLinkController(applicationContext)
        setContent {
            val state by controller.state.collectAsState()
            EdgeLinkApp(state = state, actions = controller)
        }
    }

    override fun onDestroy() {
        controller.close()
        super.onDestroy()
    }
}
