package io.github.jiunshinn.glimpse.peer

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import java.util.Date
import javax.security.auth.x500.X500Principal

/**
 * The phone's long-lived TLS client identity: a P-256 key in Android Keystore and its self-signed certificate.
 * The Mac stores the certificate fingerprint when the phone pairs. The private key never leaves the Keystore.
 */
class DeviceIdentity private constructor(
    val privateKey: PrivateKey,
    val certificate: X509Certificate,
) {
    val fingerprint: String = fingerprint(certificate)

    companion object {
        private const val ALIAS = "glimpse-device"

        fun loadOrCreate(): DeviceIdentity {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            if (!store.containsAlias(ALIAS)) create()
            val entry = store.getEntry(ALIAS, null) as KeyStore.PrivateKeyEntry
            return DeviceIdentity(entry.privateKey, entry.certificate as X509Certificate)
        }

        private fun create() {
            val now = System.currentTimeMillis()
            val day = 86_400_000L
            val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                // TLS signs a digest it made itself (NONE) or the whole message (SHA-256).
                .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256)
                .setCertificateSubject(X500Principal("CN=Glimpse for Android"))
                .setCertificateSerialNumber(BigInteger(63, SecureRandom()))
                .setCertificateNotBefore(Date(now - day))
                .setCertificateNotAfter(Date(now + 20 * 365 * day))
                .build()
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").run {
                initialize(spec)
                generateKeyPair()
            }
        }

        /** Base64url SHA-256 of the DER certificate, without padding. The same format as the Mac uses. */
        fun fingerprint(certificate: X509Certificate): String =
            Base64.getUrlEncoder().withoutPadding()
                .encodeToString(MessageDigest.getInstance("SHA-256").digest(certificate.encoded))
    }
}
