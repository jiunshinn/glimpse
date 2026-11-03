package io.github.jiunshinn.glimpse

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import io.github.jiunshinn.glimpse.peer.DeviceIdentity
import io.github.jiunshinn.glimpse.peer.Discovery
import io.github.jiunshinn.glimpse.peer.FoundMac
import io.github.jiunshinn.glimpse.peer.PairedMacs
import io.github.jiunshinn.glimpse.peer.PeerClient
import io.github.jiunshinn.glimpse.peer.PhoneLibrary
import io.github.jiunshinn.glimpse.peer.PhoneServer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Shares the phone with its paired Macs while it runs: the phone's HTTPS server, a Bonjour service,
 * and a "hello" to each Mac every 30 seconds, so the Mac knows the phone's address.
 * It is a foreground service with a notification, so sharing goes on when the screen is off.
 */
class SharingService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var server: PhoneServer? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private val found = mutableMapOf<String, FoundMac>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            prefs(this).edit().putBoolean(KEY_ON, false).apply()
            stopSelf()
            return START_NOT_STICKY
        }
        if (server != null) return START_STICKY
        val macs = PairedMacs(this)
        val names = macs.all().joinToString { it.name }
        startForeground(NOTIFICATION_ID, notification(names), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        _running.value = true

        scope.launch {
            val identity = DeviceIdentity.loadOrCreate()
            val name = phoneName(this@SharingService)
            val server = PhoneServer(identity, macs, PhoneLibrary(this@SharingService), name, BuildConfigVersion.name(this@SharingService))
            server.start()
            this@SharingService.server = server
            Log.i(TAG, "Sharing on port ${server.port}")
            register(identity.fingerprint.take(16), name, server.port)
            launch { Discovery(this@SharingService).browse().collect { found[it.id] = it; sayHello(identity, macs, server.port, name) } }
            while (isActive) {
                sayHello(identity, macs, server.port, name)
                delay(30_000)
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        _running.value = false
        scope.cancel()
        server?.stop()
        registration?.let { runCatching { (getSystemService(NSD_SERVICE) as NsdManager).unregisterService(it) } }
        multicastLock?.release()
        super.onDestroy()
    }

    private suspend fun sayHello(identity: DeviceIdentity, macs: PairedMacs, serverPort: Int, name: String) {
        for (mac in macs.all()) {
            val client = PeerClient(identity, mac.fingerprint)
            val addresses = listOfNotNull(found[mac.id]?.let { it.host to it.port }, mac.host to mac.port).distinct()
            for ((host, port) in addresses) {
                if (runCatching { client.hello(host, port, serverPort, name) }.isSuccess) {
                    if (host != mac.host || port != mac.port) macs.put(mac.copy(host = host, port = port))
                    break
                }
            }
        }
    }

    private fun register(id: String, name: String, port: Int) {
        multicastLock = (applicationContext.getSystemService(WIFI_SERVICE) as WifiManager)
            .createMulticastLock("glimpse").apply { setReferenceCounted(false); acquire() }
        val info = NsdServiceInfo().apply {
            serviceName = name
            serviceType = "_glimpse._tcp"
            setPort(port)
            setAttribute("id", id)
            setAttribute("p", "android")
            setAttribute("v", "1")
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) = Unit
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
        }
        registration = listener
        (getSystemService(NSD_SERVICE) as NsdManager).registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun notification(macNames: String): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Sharing with your Mac", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, SharingService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle("Sharing with $macNames")
            .setContentText("Your Mac can see this phone's photos and files.")
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Stop sharing", stop).build())
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val TAG = "SharingService"
        private const val CHANNEL = "sharing"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_STOP = "stop"

        private val _running = MutableStateFlow(false)
        val running: StateFlow<Boolean> = _running

        fun start(context: Context) {
            prefs(context).edit().putBoolean(KEY_ON, true).apply()
            context.startForegroundService(Intent(context, SharingService::class.java))
        }

        fun stop(context: Context) {
            prefs(context).edit().putBoolean(KEY_ON, false).apply()
            context.startService(Intent(context, SharingService::class.java).setAction(ACTION_STOP))
        }

        /** Starts sharing again when the app opens, if the user left it on and a Mac is paired. */
        fun resumeIfOn(context: Context) {
            if (prefs(context).getBoolean(KEY_ON, false) && PairedMacs(context).all().isNotEmpty() && !running.value) {
                context.startForegroundService(Intent(context, SharingService::class.java))
            }
        }

        private const val KEY_ON = "on"
        private fun prefs(context: Context) = context.getSharedPreferences("sharing", Context.MODE_PRIVATE)

        fun phoneName(context: Context): String =
            Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) ?: Build.MODEL
    }
}

private object BuildConfigVersion {
    fun name(context: Context): String =
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "dev"
}
