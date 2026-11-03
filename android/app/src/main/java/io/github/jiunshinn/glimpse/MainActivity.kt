package io.github.jiunshinn.glimpse

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import io.github.jiunshinn.glimpse.ui.GlimpseApp
import io.github.jiunshinn.glimpse.ui.GlimpseTheme

class MainActivity : ComponentActivity() {
    private val viewModel: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            GlimpseTheme {
                GlimpseApp(viewModel)
            }
        }
        if (savedInstanceState == null) handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onStart() {
        super.onStart()
        viewModel.onForeground()
        SharingService.resumeIfOn(this)
    }

    override fun onStop() {
        super.onStop()
        viewModel.onBackground()
    }

    /** A `glimpse://pair` link opened from another app, for example the system camera. */
    private fun handle(intent: Intent?) {
        val data = intent?.data ?: return
        if (intent.action == Intent.ACTION_VIEW) viewModel.pair(data.toString(), fromOutside = true)
    }
}
