package io.github.jiunshinn.glimpse.peer

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import java.io.File

/** Decodes the shared samples in /protocol/fixtures, so a change on the Mac side fails here too. */
class ProtocolFixturesTest {
    private val fixtures = File(System.getProperty("user.dir"), "../../protocol/fixtures")

    private fun read(name: String) = File(fixtures, name).readText()

    @Test
    fun infoFromTheMac() {
        val info = PeerInfo.fromJson(JSONObject(read("info-mac.json")))
        assertEquals("SG42CPzzmi5RtbSM", info.id)
        assertEquals("mac", info.platform)
        assertEquals(listOf(1), info.protocols)
        assertEquals(true, info.paired)
    }

    @Test
    fun pairingLinkFromTheMac() {
        val link = PairingLink.parse(read("pairing-link.txt"))
        assertNotNull(link)
        assertEquals("SG42CPzzmi5RtbSM", link!!.fingerprint.take(16))
    }
}
