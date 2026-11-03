package io.github.jiunshinn.glimpse

import android.content.Intent
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
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
        // The cable is still in accessory mode from before (for example after an app update): use it again.
        val usb = getSystemService(USB_SERVICE) as UsbManager
        usb.accessoryList?.firstOrNull { it.manufacturer == "Glimpse" && usb.hasPermission(it) }
            ?.let { SharingService.startUsb(this, it) }
    }

    override fun onStop() {
        super.onStop()
        viewModel.onBackground()
    }

    /** A `glimpse://pair` link opened from another app, for example the system camera. */
    private fun handle(intent: Intent?) {
        if (intent?.action == UsbManager.ACTION_USB_ACCESSORY_ATTACHED) {
            // Android gives the permission for the accessory with this intent.
            val accessory = if (android.os.Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
            } else {
                @Suppress("DEPRECATION") intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
            }
            accessory?.let { SharingService.startUsb(this, it) }
            return
        }
        val data = intent?.data ?: return
        if (intent.action == Intent.ACTION_VIEW) viewModel.pair(data.toString(), fromOutside = true)
    }
}
