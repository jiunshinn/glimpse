package io.github.jiunshinn.glimpse.peer

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import java.util.concurrent.Executors

/** A Glimpse Mac on the local network, found with Bonjour. */
data class FoundMac(val id: String, val host: String, val port: Int)

/**
 * Browses for `_glimpse._tcp` and emits each Mac it can resolve. The TXT record `id` matches [PairedMac.id].
 */
class Discovery(context: Context) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager

    fun browse(): Flow<FoundMac> = callbackFlow {
        val executor = Executors.newSingleThreadExecutor()
        val resolving = mutableListOf<NsdServiceInfo>()
        var busy = false

        fun emit(info: NsdServiceInfo) {
            val id = info.attributes["id"]?.toString(Charsets.UTF_8) ?: return
            val address = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses.firstOrNull() else @Suppress("DEPRECATION") info.host
            val host = address?.hostAddress ?: return
            trySend(FoundMac(id, host, info.port))
        }

        // Before Android 14, NsdManager resolves one service at a time.
        fun resolveNext() {
            if (busy) return
            val next = resolving.removeFirstOrNull() ?: return
            busy = true
            @Suppress("DEPRECATION")
            nsd.resolveService(next, object : NsdManager.ResolveListener {
                override fun onServiceResolved(info: NsdServiceInfo) {
                    emit(info)
                    executor.execute { busy = false; resolveNext() }
                }

                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    executor.execute { busy = false; resolveNext() }
                }
            })
        }

        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                executor.execute { resolving += info; resolveNext() }
            }

            override fun onServiceLost(info: NsdServiceInfo) = Unit
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                close()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        awaitClose {
            runCatching { nsd.stopServiceDiscovery(listener) }
            executor.shutdown()
        }
    }

    private companion object {
        const val SERVICE_TYPE = "_glimpse._tcp"
    }
}
