package com.applivery.soar.mobile

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.SubjectPublicKeyInfo
import org.bouncycastle.operator.ContentSigner
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.bouncycastle.pkcs.PKCS10CertificationRequest
import org.bouncycastle.pkcs.PKCS10CertificationRequestBuilder
import java.io.ByteArrayInputStream
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec

/**
 * mTLS device identity — AndroidKeyStore-backed EC keypair generation and
 * PKCS#10 CSR building for POST /api/device-mtls/register (backend
 * deviceMtls.service.ts). See ios/Runner/MtlsIdentityPlugin.swift for the
 * iOS equivalent (Keychain SecKey) and lib/identity/mtls_identity.dart for
 * the Dart orchestration that calls this (the actual register HTTP request,
 * response parsing) — this plugin ONLY does the on-device crypto,
 * deliberately: the private key never leaves AndroidKeyStore (non-exportable,
 * hardware-backed on devices with a StrongBox/TEE, software-backed
 * fallback otherwise), so Dart can never touch raw key material — only
 * PEM-encoded CSRs and certificates (public data) ever cross the platform
 * channel.
 *
 * Renewal (POST /api/device-mtls/renew, which needs an mTLS-authenticated
 * HTTP client bound to this hardware key rather than just CSR generation) is
 * NOT implemented yet — see ARCHITECTURE.md's identity section for what's
 * still open. This plugin currently only covers first-time registration.
 *
 * UNVERIFIED against a real device/emulator — no local Android toolchain in
 * this project's own tooling to compile or exercise this against (same
 * "CI/device is the real check" story as the rest of this repo, and the two
 * desktop agent repos before it). Before trusting this in practice: confirm
 * generateCsr's output parses as a valid CSR (`openssl req -in csr.pem -noout
 * -text` — write it to a file from the debug screen's own output, or
 * temporarily log it), and confirm storeCertificate's setKeyEntry call
 * actually re-associates the issued certificate with the SAME key that
 * signed the CSR (mismatched key/cert pairing would silently break every
 * future mTLS handshake using this identity).
 */
class MtlsIdentityPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val METHOD_CHANNEL = "es.applivery.soar/mtls_identity"
        private const val KEYSTORE_ALIAS = "es.applivery.soar.mtls"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    }

    private var methodChannel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "hasIdentity" -> result.success(hasIdentity())
                "generateCsr" -> {
                    val commonName = call.argument<String>("commonName")
                    if (commonName.isNullOrBlank()) {
                        result.error("bad_args", "commonName is required", null)
                        return
                    }
                    result.success(generateCsr(commonName))
                }
                "storeCertificate" -> {
                    val certPem = call.argument<String>("certPem")
                    if (certPem.isNullOrBlank()) {
                        result.error("bad_args", "certPem is required", null)
                        return
                    }
                    storeCertificate(certPem)
                    result.success(true)
                }
                "clearIdentity" -> {
                    clearIdentity()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("mtls_identity_error", e.message, null)
        }
    }

    private fun keyStore(): KeyStore {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE)
        ks.load(null)
        return ks
    }

    /**
     * A freshly-generated AndroidKeyStore keypair always has an automatic
     * self-signed placeholder certificate (Android's own behavior, so
     * getCertificate/getEntry always have something to return even before
     * real enrollment finishes) — this alone can't distinguish "key
     * generated, CSR pending" from "fully enrolled with a real issued
     * cert". Good enough for this plugin's own alias-exists check; the Dart
     * orchestration layer is what actually tracks enrollment completion
     * (e.g. having successfully parsed a register response), not this.
     */
    private fun hasIdentity(): Boolean {
        val ks = keyStore()
        return ks.containsAlias(KEYSTORE_ALIAS) && ks.getCertificate(KEYSTORE_ALIAS) != null
    }

    /**
     * Generates a FRESH P-256 keypair in AndroidKeyStore (overwriting any
     * previous entry under the same alias — a half-finished enrollment
     * attempt's key is never reused, matching the desktop agents'
     * generateMtlsKeyAndCsr, which also generates a new key per attempt),
     * then builds and signs a PKCS#10 CSR for it with Bouncy Castle.
     */
    private fun generateCsr(commonName: String): String {
        val keyPairGenerator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(KEYSTORE_ALIAS, KeyProperties.PURPOSE_SIGN)
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .build()
        keyPairGenerator.initialize(spec)
        val keyPair = keyPairGenerator.generateKeyPair()

        val subject = X500Name("CN=$commonName")
        val publicKeyInfo = SubjectPublicKeyInfo.getInstance(keyPair.public.encoded)
        val csrBuilder = PKCS10CertificationRequestBuilder(subject, publicKeyInfo)
        // Signs using the AndroidKeyStore-resident PrivateKey handle
        // directly — the actual EC signing operation happens inside the
        // keystore/hardware, the raw private key material is never read
        // into this process' memory at any point.
        val signer: ContentSigner = JcaContentSignerBuilder("SHA256withECDSA")
            .setProvider(ANDROID_KEYSTORE)
            .build(keyPair.private)
        val csr: PKCS10CertificationRequest = csrBuilder.build(signer)

        return toPem(csr.encoded, "CERTIFICATE REQUEST")
    }

    /**
     * Pairs the backend-issued certificate with the private key already
     * sitting in AndroidKeyStore from generateCsr — AndroidKeyStore
     * supports updating just the certificate chain of an existing
     * keystore-resident private key entry via setKeyEntry, without ever
     * needing (or being able) to re-supply the private key material itself.
     */
    private fun storeCertificate(certPem: String) {
        val ks = keyStore()
        val entry = ks.getEntry(KEYSTORE_ALIAS, null) as? KeyStore.PrivateKeyEntry
            ?: throw IllegalStateException("No pending key found — call generateCsr first.")
        val privateKey: PrivateKey = entry.privateKey

        val certFactory = CertificateFactory.getInstance("X.509")
        val cert = certFactory.generateCertificate(ByteArrayInputStream(certPem.toByteArray())) as X509Certificate

        ks.setKeyEntry(KEYSTORE_ALIAS, privateKey, null, arrayOf(cert))
    }

    private fun clearIdentity() {
        val ks = keyStore()
        if (ks.containsAlias(KEYSTORE_ALIAS)) {
            ks.deleteEntry(KEYSTORE_ALIAS)
        }
    }

    /** RFC 7468-style PEM: 64-char base64 lines, explicit BEGIN/END labels. */
    private fun toPem(der: ByteArray, label: String): String {
        val base64 = Base64.encodeToString(der, Base64.NO_WRAP)
        val wrapped = base64.chunked(64).joinToString("\n")
        return "-----BEGIN $label-----\n$wrapped\n-----END $label-----\n"
    }
}
