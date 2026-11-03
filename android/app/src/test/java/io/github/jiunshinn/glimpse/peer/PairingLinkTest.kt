package io.github.jiunshinn.glimpse.peer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PairingLinkTest {
    private val fingerprint = "SG42CPzzmi5RtbSMEHFV9LZeclqR7PQhN6zQewlDUIo"

    @Test
    fun parsesTheMacLink() {
        val link = PairingLink.parse("glimpse://pair?h=192.168.219.104&port=53817&fp=$fingerprint&code=O-a_VzJH5HuMo4402SayZg")
        assertEquals(PairingLink("192.168.219.104", 53817, fingerprint, "O-a_VzJH5HuMo4402SayZg"), link)
    }

    @Test
    fun ignoresUnknownParameters() {
        val link = PairingLink.parse(" glimpse://pair?code=abc&fp=$fingerprint&port=1&h=10.0.0.2&n=Mac \n")
        assertEquals(PairingLink("10.0.0.2", 1, fingerprint, "abc"), link)
    }

    @Test
    fun rejectsOtherLinks() {
        assertNull(PairingLink.parse("https://example.com/pair?h=1.2.3.4&port=1&fp=$fingerprint&code=x"))
        assertNull(PairingLink.parse("glimpse://open?h=1.2.3.4&port=1&fp=$fingerprint&code=x"))
        assertNull(PairingLink.parse("glimpse://pair?h=1.2.3.4&port=70000&fp=$fingerprint&code=x"))
        assertNull(PairingLink.parse("glimpse://pair?h=1.2.3.4&port=1&fp=short&code=x"))
        assertNull(PairingLink.parse("glimpse://pair?h=1.2.3.4&port=1&fp=$fingerprint"))
        assertNull(PairingLink.parse("not a link"))
    }
}
