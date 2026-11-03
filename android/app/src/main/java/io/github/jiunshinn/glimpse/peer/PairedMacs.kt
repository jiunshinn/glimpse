package io.github.jiunshinn.glimpse.peer

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** A Mac this phone paired with. `host` and `port` are the last known address; Bonjour updates them. */
data class PairedMac(
    val fingerprint: String,
    val name: String,
    val host: String,
    val port: Int,
) {
    val id: String get() = fingerprint.take(16)
}

/** Stores the paired Macs in app-private preferences. A fingerprint is public data, so no encryption is needed. */
class PairedMacs(context: Context) {
    private val prefs = context.getSharedPreferences("paired_macs", Context.MODE_PRIVATE)

    fun all(): List<PairedMac> {
        val array = runCatching { JSONArray(prefs.getString(KEY, "[]")) }.getOrElse { JSONArray() }
        return List(array.length()) { index ->
            val item = array.getJSONObject(index)
            PairedMac(item.getString("fp"), item.getString("name"), item.getString("host"), item.getInt("port"))
        }
    }

    fun put(mac: PairedMac) = save(all().filterNot { it.fingerprint == mac.fingerprint } + mac)

    fun remove(mac: PairedMac) = save(all().filterNot { it.fingerprint == mac.fingerprint })

    private fun save(macs: List<PairedMac>) {
        val array = JSONArray()
        macs.forEach {
            array.put(JSONObject().put("fp", it.fingerprint).put("name", it.name).put("host", it.host).put("port", it.port))
        }
        prefs.edit().putString(KEY, array.toString()).apply()
    }

    private companion object {
        const val KEY = "macs"
    }
}
