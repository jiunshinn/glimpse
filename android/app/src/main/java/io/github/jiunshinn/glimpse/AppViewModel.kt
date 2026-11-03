package io.github.jiunshinn.glimpse

import android.app.Application
import android.os.Build
import android.provider.Settings
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.jiunshinn.glimpse.peer.DeviceIdentity
import io.github.jiunshinn.glimpse.peer.Discovery
import io.github.jiunshinn.glimpse.peer.FoundMac
import io.github.jiunshinn.glimpse.peer.PairedMac
import io.github.jiunshinn.glimpse.peer.PairedMacs
import io.github.jiunshinn.glimpse.peer.PairingLink
import io.github.jiunshinn.glimpse.peer.PeerClient
import io.github.jiunshinn.glimpse.peer.PeerException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class MacStatus { Searching, Connected, Unreachable, UnpairedByMac }

data class MacRow(val mac: PairedMac, val status: MacStatus)

sealed interface Pairing {
    data object Idle : Pairing
    data object Working : Pairing
    /** A link from outside the app (a web page, another app) waits for the user to say yes. */
    data class Confirm(val link: PairingLink, val macName: String) : Pairing
    data class Done(val macName: String) : Pairing
    data class Failed(val message: String) : Pairing
}

data class UiState(
    val macs: List<MacRow> = emptyList(),
    val pairing: Pairing = Pairing.Idle,
)

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val store = PairedMacs(application)
    private val discovery = Discovery(application)
    private var identity: DeviceIdentity? = null
    /** Addresses from Bonjour, by Mac ID. They are newer than the stored address. */
    private val found = mutableMapOf<String, FoundMac>()
    private var foreground: Job? = null

    private val _state = MutableStateFlow(UiState(macs = store.all().map { MacRow(it, MacStatus.Searching) }))
    val state: StateFlow<UiState> = _state.asStateFlow()

    /** Browses and checks the Macs only while the app shows. */
    fun onForeground() {
        if (foreground != null) return
        foreground = viewModelScope.launch {
            launch {
                discovery.browse().collect { mac ->
                    found[mac.id] = mac
                    store.all().firstOrNull { it.id == mac.id }?.let { refresh(it) }
                }
            }
            while (isActive) {
                store.all().forEach { launch { refresh(it) } }
                delay(15_000)
            }
        }
    }

    fun onBackground() {
        foreground?.cancel()
        foreground = null
    }

    /** Starts pairing from a scanned or pasted code. [fromOutside] asks the user first. */
    fun pair(text: String, fromOutside: Boolean = false) {
        if (_state.value.pairing == Pairing.Working) return
        val link = PairingLink.parse(text)
        if (link == null) {
            setPairing(Pairing.Failed("This is not a Glimpse pairing code. On the Mac, choose File › Connect Phone, then scan the code there."))
            return
        }
        setPairing(Pairing.Working)
        viewModelScope.launch {
            try {
                val client = client(link.fingerprint)
                if (fromOutside) {
                    val info = client.info(link.host, link.port)
                    setPairing(Pairing.Confirm(link, info.name))
                } else {
                    finishPairing(client, link)
                }
            } catch (e: PeerException) {
                setPairing(Pairing.Failed(message(e)))
            }
        }
    }

    fun confirmPairing() {
        val confirm = _state.value.pairing as? Pairing.Confirm ?: return
        setPairing(Pairing.Working)
        viewModelScope.launch {
            try {
                finishPairing(client(confirm.link.fingerprint), confirm.link)
            } catch (e: PeerException) {
                setPairing(Pairing.Failed(message(e)))
            }
        }
    }

    fun dismissPairing() = setPairing(Pairing.Idle)

    fun unpair(mac: PairedMac) {
        store.remove(mac)
        _state.update { state -> state.copy(macs = state.macs.filterNot { it.mac.fingerprint == mac.fingerprint }) }
    }

    private suspend fun finishPairing(client: PeerClient, link: PairingLink) {
        client.pair(link.host, link.port, link.code, phoneName())
        val info = client.info(link.host, link.port)
        val mac = PairedMac(link.fingerprint, info.name, link.host, link.port)
        store.put(mac)
        setRow(MacRow(mac, MacStatus.Connected))
        setPairing(Pairing.Done(info.name))
    }

    private suspend fun refresh(mac: PairedMac) {
        val client = runCatching { client(mac.fingerprint) }.getOrNull() ?: return
        val addresses = listOfNotNull(found[mac.id]?.let { it.host to it.port }, mac.host to mac.port).distinct()
        for ((host, port) in addresses) {
            try {
                val info = client.info(host, port)
                val updated = mac.copy(name = info.name, host = host, port = port)
                if (updated != mac) store.put(updated)
                setRow(MacRow(updated, if (info.paired) MacStatus.Connected else MacStatus.UnpairedByMac))
                return
            } catch (_: PeerException) {
                // Try the next address.
            }
        }
        setRow(MacRow(mac, MacStatus.Unreachable))
    }

    private suspend fun client(fingerprint: String): PeerClient {
        val identity = identity ?: withContext(Dispatchers.IO) { DeviceIdentity.loadOrCreate() }.also { identity = it }
        return PeerClient(identity, fingerprint)
    }

    private fun setRow(row: MacRow) = _state.update { state ->
        val others = state.macs.filterNot { it.mac.fingerprint == row.mac.fingerprint }
        // A Mac that was unpaired on this phone in the meantime stays gone.
        if (store.all().none { it.fingerprint == row.mac.fingerprint }) state
        else state.copy(macs = (others + row).sortedBy { it.mac.name.lowercase() })
    }

    private fun setPairing(pairing: Pairing) = _state.update { it.copy(pairing = pairing) }

    private fun phoneName(): String =
        Settings.Global.getString(getApplication<Application>().contentResolver, Settings.Global.DEVICE_NAME)
            ?: Build.MODEL

    private fun message(e: PeerException): String = when (e.code) {
        "unreachable" -> "Glimpse could not reach the Mac. Make sure Glimpse is open on the Mac, and that the phone and the Mac use the same Wi-Fi network."
        "no_route" -> "The phone cannot see the Mac on this Wi-Fi. The Mac may be asleep, or the router may stop Wi-Fi devices from talking to each other. " +
            "If the Mac is awake, turn on this phone's hotspot, connect the Mac to it, and scan a new code."
        "pairing_closed" -> "The code expired. On the Mac, make a new code and scan it again."
        "bad_code" -> "The code did not work. Scan the code on the Mac again."
        "wrong_mac" -> "The Mac at this address is not the Mac in the code. Scan the code again."
        else -> e.message ?: "Pairing failed."
    }
}
