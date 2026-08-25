package com.applivery.soar.mobile

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.AlgorithmIdentifier
import org.bouncycastle.asn1.x509.SubjectPublicKeyInfo
import org.bouncycastle.asn1.x9.X9ObjectIdentifiers
import org.bouncycastle.operator.ContentSigner
import org.bouncycastle.pkcs.PKCS10CertificationRequest
import org.bouncycastle.pkcs.PKCS10CertificationRequestBuilder
import java.io.ByteArrayInputStream
import java.io.OutputStream
import java.net.Socket
import java.net.URL
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Principal
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.KeyManager
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509ExtendedKeyManager

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
 * Also exposes `mtlsRequest`: a real mTLS-authenticated HTTP request (client
 * certificate presented via a KeyManagerFactory scoped to this keystore
 * alias) used by GET /api/device-data/agent-status today, and by
 * POST /api/device-mtls/renew once that gets a Dart-side caller — see
 * ARCHITECTURE.md §2.6.
 *
 * UNVERIFIED against a real device/emulator by this plugin's own tooling —
 * no local Android toolchain in this sandbox to compile or exercise this
 * against (same "CI/device is the real check" story as the rest of this
 * repo, and the two desktop agent repos before it). Registration
 * (generateCsr/storeCertificate) has been confirmed end-to-end by the user
 * on a real emulator against the live Applivery fleet — see
 * ARCHITECTURE.md §2.4. mtlsRequest itself has not yet had the same
 * live-device confirmation; before trusting it in practice, confirm a real
 * agent-status call succeeds against an enrolled device on a workspace with
 * mTLS enforcement enabled.
 */
class MtlsIdentityPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val METHOD_CHANNEL = "es.applivery.soar/mtls_identity"
        private const val KEYSTORE_ALIAS = "es.applivery.soar.mtls"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val LOG_TAG = "MtlsIdentityPlugin"
    }

    private var methodChannel: MethodChannel? = null

    // Backs the async "mtlsRequest" method only — every other method here is
    // fast, synchronous keystore/BouncyCastle work that's fine on the
    // platform channel's own calling thread. Network I/O is not, so it gets
    // its own scope rather than blocking Flutter's method-channel thread.
    private val pluginScope = CoroutineScope(Dispatchers.Main)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // Temporary but deliberate: the catch-all below used to swallow every
        // exception into a Dart-facing message string with no native-side
        // Log call at all, which is why the Android digest debugging arc
        // (see generateCsr's doc comment) kept producing screenshots of the
        // Dart error text but silent, empty logcat around the actual moment
        // of failure — there was nothing tagged MtlsIdentityPlugin to filter
        // for. Log.e here (and around generateCsr specifically, since that's
        // the current suspect) is the fix: `adb logcat -s MtlsIdentityPlugin`
        // or `adb logcat | grep MtlsIdentityPlugin` now always shows the full
        // exception + stack trace for every plugin call, success or failure.
        Log.i(LOG_TAG, "onMethodCall: ${call.method}")
        try {
            when (call.method) {
                "hasIdentity" -> {
                    val result0 = hasIdentity()
                    Log.i(LOG_TAG, "hasIdentity: $result0")
                    result.success(result0)
                }
                "generateCsr" -> {
                    val commonName = call.argument<String>("commonName")
                    if (commonName.isNullOrBlank()) {
                        result.error("bad_args", "commonName is required", null)
                        return
                    }
                    Log.i(LOG_TAG, "generateCsr: starting for commonName=$commonName")
                    try {
                        val csr = generateCsr(commonName)
                        Log.i(LOG_TAG, "generateCsr: succeeded, CSR length=${csr.length}")
                        result.success(csr)
                    } catch (e: Exception) {
                        Log.e(LOG_TAG, "generateCsr: FAILED for commonName=$commonName", e)
                        throw e
                    }
                }
                "storeCertificate" -> {
                    val certPem = call.argument<String>("certPem")
                    if (certPem.isNullOrBlank()) {
                        result.error("bad_args", "certPem is required", null)
                        return
                    }
                    val caCertPem = call.argument<String>("caCertPem")
                    storeCertificate(certPem, caCertPem)
                    result.success(true)
                }
                "clearIdentity" -> {
                    clearIdentity()
                    result.success(true)
                }
                "mtlsRequest" -> {
                    val urlString = call.argument<String>("url")
                    val method = call.argument<String>("method")
                    if (urlString.isNullOrBlank() || method.isNullOrBlank()) {
                        result.error("bad_args", "url and method are required", null)
                        return
                    }
                    @Suppress("UNCHECKED_CAST")
                    val headers = (call.argument<Map<String, String>>("headers")) ?: emptyMap()
                    val body = call.argument<String>("body")
                    pluginScope.launch {
                        try {
                            val response = withContext(Dispatchers.IO) {
                                mtlsRequest(method, urlString, headers, body)
                            }
                            result.success(response)
                        } catch (e: Exception) {
                            Log.e(LOG_TAG, "mtlsRequest: FAILED for $method $urlString", e)
                            result.error("mtls_request_error", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(LOG_TAG, "onMethodCall(${call.method}): FAILED", e)
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
     * self-signed placeholder certificate (Android's own behavior — subject
     * == issuer == "CN=Fake" in practice, confirmed via a real device's
     * logcat output, not merely documented), present the instant the keypair
     * exists and well before any real enrollment completes. Originally this
     * method just checked `getCertificate() != null`, on the theory that the
     * Dart orchestration layer (having successfully parsed a register
     * response) was what actually tracked real completion — but
     * `_maybeAutoEnroll` (mtls_identity.dart) only ever calls enroll() again
     * when THIS method reports false, so a half-finished attempt (key
     * generated, then register/store never completing — e.g. a transient
     * network error) left a placeholder-only identity that this method
     * reported as "has one," permanently blocking retry and letting the
     * bogus placeholder get presented as a real client certificate on every
     * subsequent mTLS handshake attempt. Confirmed as the actual root cause
     * of a real Android device stuck presenting `CN=Fake` to the server
     * indefinitely — not a hypothetical.
     *
     * Fixed by checking self-signedness instead of mere presence: a real
     * certificate issued through POST /api/device-mtls/register is never
     * self-signed (its issuer is always the workspace's CA, never the
     * device's own key), so subject != issuer is a structural, Android-
     * version-independent way to tell "real, backend-issued identity" apart
     * from "AndroidKeyStore's own placeholder," without depending on
     * matching Android's specific (undocumented, possibly OEM-varying)
     * placeholder subject string.
     */
    private fun hasIdentity(): Boolean {
        val ks = keyStore()
        if (!ks.containsAlias(KEYSTORE_ALIAS)) return false
        val cert = ks.getCertificate(KEYSTORE_ALIAS) as? X509Certificate ?: return false
        return cert.subjectX500Principal != cert.issuerX500Principal
    }

    /**
     * A BouncyCastle [ContentSigner] that signs PKCS#10 CSR bytes with an
     * AndroidKeyStore-resident EC private key — a custom implementation
     * because every combination tried of {explicit "AndroidKeyStore"
     * provider name} x {digest(s) declared on the key} x
     * {"SHA256withECDSA" vs "NONEwithECDSA"} has failed on real hardware so
     * far, confirmed via full stack traces, not guessed:
     *
     *  - SHA256 declared alone, `Signature.getInstance("SHA256withECDSA",
     *    "AndroidKeyStore")`: worked for CSR signing historically, but left
     *    the key unable to do the TLS handshake's raw-digest
     *    CertificateVerify signature (`INCOMPATIBLE_DIGEST` — the original
     *    root cause this whole arc started from).
     *  - Both digests declared, `Signature.getInstance("SHA256withECDSA",
     *    "AndroidKeyStore")`: `NoSuchAlgorithmException: no such algorithm:
     *    SHA256WITHECDSA for provider AndroidKeyStore`.
     *  - NONE declared alone, `Signature.getInstance("NONEwithECDSA",
     *    "AndroidKeyStore")`: `NoSuchAlgorithmException: no such algorithm:
     *    NONEwithECDSA for provider AndroidKeyStore`.
     *  - Both digests declared, `Signature.getInstance("NONEwithECDSA",
     *    "AndroidKeyStore")`: same `NoSuchAlgorithmException`, confirmed on
     *    both the emulator and a real Samsung S23 Ultra with full stack
     *    traces pointing at this exact call
     *    (`Sha256WithEcdsaSigner.getSignature`).
     *
     * So "NONEwithECDSA" is not registered as a public JCA algorithm name
     * under AndroidKeyStore's provider on this platform, in any digest
     * configuration tried — that door is closed. What's untested is asking
     * for "SHA256withECDSA" WITHOUT naming a provider — a known, documented
     * AndroidKeyStore quirk (and the pattern Android's own official crypto
     * samples use) is that `Signature.getInstance(algorithm, providerName)`
     * (name-based service lookup against that provider's static table) and
     * `Signature.getInstance(algorithm)` (searches every installed
     * provider, then `initSign(key)` resolves the actual implementation
     * from the key object's own runtime type) can disagree — some
     * AndroidKeyStore versions only populate the per-key virtual service
     * table that the second form's dispatch reaches, not the static one the
     * first form's exact-name lookup checks.
     *
     * Buffers the raw TBS bytes directly into the Signature object (no
     * manual hashing here — "SHA256withECDSA" does its own hashing
     * internally, unlike the abandoned NONEwithECDSA approach which needed
     * the digest computed in application code first).
     *
     * getAlgorithmIdentifier() reports ecdsa-with-SHA256
     * (OID 1.2.840.10045.4.3.2), matching the algorithm actually used here.
     */
    private class Sha256WithEcdsaSigner(privateKey: PrivateKey) : ContentSigner {
        private val signature: Signature = Signature.getInstance("SHA256withECDSA").apply {
            initSign(privateKey)
        }
        private val signingStream = object : OutputStream() {
            override fun write(b: Int) {
                signature.update(b.toByte())
            }

            override fun write(b: ByteArray, off: Int, len: Int) {
                signature.update(b, off, len)
            }
        }

        override fun getAlgorithmIdentifier(): AlgorithmIdentifier =
            AlgorithmIdentifier(X9ObjectIdentifiers.ecdsa_with_SHA256)

        override fun getOutputStream(): OutputStream = signingStream

        override fun getSignature(): ByteArray = signature.sign()
    }

    /**
     * Generates a FRESH P-256 keypair in AndroidKeyStore (overwriting any
     * previous entry under the same alias — a half-finished enrollment
     * attempt's key is never reused, matching the desktop agents'
     * generateMtlsKeyAndCsr, which also generates a new key per attempt),
     * then builds and signs a PKCS#10 CSR for it with Bouncy Castle.
     *
     * setDigests declares BOTH DIGEST_SHA256 and DIGEST_NONE. NONE is what
     * every TLS engine (Conscrypt included) actually uses for the
     * handshake's CertificateVerify signature: TLS computes its own
     * transcript hash outside the keystore and asks the private key to sign
     * that raw digest directly — a digest AndroidKeyStore's Keymaster
     * refuses at sign time with `INCOMPATIBLE_DIGEST` unless DIGEST_NONE was
     * explicitly declared when the key was generated, no matter how valid
     * the issued certificate or its chain is. This was the actual root
     * cause of `mtlsRequest`'s Android client-cert handshake never
     * succeeding (see ARCHITECTURE.md §2.6) — confirmed via the exact
     * `Error::Km(INCOMPATIBLE_DIGEST)` stack trace Conscrypt logs when this
     * happens, not guessed. SHA256 is needed too, since it's what CSR
     * signing below uses.
     *
     * Getting CSR signing itself to work on top of that dual-digest key took
     * several real, evidence-driven rounds (every one of these confirmed via
     * a full stack trace, none guessed):
     *
     *  - `Signature.getInstance("SHA256withECDSA", "AndroidKeyStore")` with
     *    BOTH digests declared: `NoSuchAlgorithmException: no such
     *    algorithm: SHA256WITHECDSA for provider AndroidKeyStore`.
     *  - `Signature.getInstance("NONEwithECDSA", "AndroidKeyStore")` with
     *    DIGEST_NONE declared alone: `NoSuchAlgorithmException: no such
     *    algorithm: NONEwithECDSA for provider AndroidKeyStore`.
     *  - The same `NONEwithECDSA` call with BOTH digests declared: identical
     *    `NoSuchAlgorithmException`, confirmed on both an emulator and a
     *    real Samsung S23 Ultra — ruling out "NONEwithECDSA" as ever being a
     *    usable public JCA algorithm name under AndroidKeyStore's provider
     *    on this platform, in any digest configuration.
     *
     * The combination actually in use now — see `Sha256WithEcdsaSigner`'s
     * own doc comment for the full reasoning — is `Signature.getInstance(
     * "SHA256withECDSA")` with NO explicit provider name, letting JCA
     * resolve the implementation from the AndroidKeyStore-resident
     * PrivateKey object itself rather than doing a name-based lookup
     * against "AndroidKeyStore"'s static service table. **Not yet confirmed
     * working — pending re-test.**
     */
    private fun generateCsr(commonName: String): String {
        val keyPairGenerator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(KEYSTORE_ALIAS, KeyProperties.PURPOSE_SIGN)
            .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_NONE)
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
        // into this process' memory at any point. See Sha256WithEcdsaSigner's
        // own doc comment for why this isn't JcaContentSignerBuilder
        // ("SHA256withECDSA") anymore.
        val signer: ContentSigner = Sha256WithEcdsaSigner(keyPair.private)
        val csr: PKCS10CertificationRequest = csrBuilder.build(signer)

        return toPem(csr.encoded, "CERTIFICATE REQUEST")
    }

    /**
     * Pairs the backend-issued certificate with the private key already
     * sitting in AndroidKeyStore from generateCsr — AndroidKeyStore
     * supports updating just the certificate chain of an existing
     * keystore-resident private key entry via setKeyEntry, without ever
     * needing (or being able) to re-supply the private key material itself.
     *
     * [caCertPem], when present (POST /api/device-mtls/register's response
     * includes it alongside certPem — see deviceMtls.service.ts), is stored
     * as the SECOND entry in the chain so the full leaf+CA chain is what a
     * KeyManagerFactory built from this keystore later presents during a TLS
     * handshake (see mtlsRequest below) — some server-side TLS stacks reject
     * a client cert whose issuer isn't included in the presented chain, even
     * when that issuer is otherwise trusted, so this isn't just belt-and-
     * suspenders.
     */
    private fun storeCertificate(certPem: String, caCertPem: String?) {
        val ks = keyStore()
        val entry = ks.getEntry(KEYSTORE_ALIAS, null) as? KeyStore.PrivateKeyEntry
            ?: throw IllegalStateException("No pending key found — call generateCsr first.")
        val privateKey: PrivateKey = entry.privateKey

        val certFactory = CertificateFactory.getInstance("X.509")
        val cert = certFactory.generateCertificate(ByteArrayInputStream(certPem.toByteArray())) as X509Certificate

        val chain: Array<X509Certificate> = if (caCertPem.isNullOrBlank()) {
            arrayOf(cert)
        } else {
            val caCert = certFactory.generateCertificate(
                ByteArrayInputStream(caCertPem.toByteArray())
            ) as X509Certificate
            arrayOf(cert, caCert)
        }

        ks.setKeyEntry(KEYSTORE_ALIAS, privateKey, null, chain)

        // Temporary diagnostic logging — NPM/nginx is rejecting Android's
        // presented certificate with its own internal 495 ("client sent
        // invalid certificate", surfaced as HTTP 400) before the request
        // ever reaches the backend, and its error log at the current log
        // level doesn't include the actual OpenSSL verification failure
        // reason. This dumps exactly what got stored (chain length, each
        // cert's subject/issuer/validity) to logcat — all public certificate
        // data, nothing sensitive — so it's visible in `flutter run`'s
        // console output on the next enroll without needing any new UI or
        // further nginx-side digging. Remove once the mismatch (if any) is
        // found — see ARCHITECTURE.md §2.6.
        Log.i(LOG_TAG, "storeCertificate: chain has ${chain.size} certificate(s)")
        chain.forEachIndexed { index, c ->
            Log.i(
                LOG_TAG,
                "storeCertificate: chain[$index] subject=${c.subjectX500Principal} " +
                    "issuer=${c.issuerX500Principal} notBefore=${c.notBefore} notAfter=${c.notAfter} " +
                    "serialNumber=${c.serialNumber}"
            )
        }
        // Re-read the chain back from the keystore itself (not the local
        // `chain` array above) — confirms what KeyManagerFactory will
        // actually see later, in case setKeyEntry silently normalizes or
        // drops anything.
        val storedChain = ks.getCertificateChain(KEYSTORE_ALIAS)
        Log.i(LOG_TAG, "storeCertificate: re-read ${storedChain?.size ?: 0} certificate(s) back from AndroidKeyStore")
    }

    private fun clearIdentity() {
        val ks = keyStore()
        if (ks.containsAlias(KEYSTORE_ALIAS)) {
            ks.deleteEntry(KEYSTORE_ALIAS)
        }
    }

    /**
     * Performs an mTLS-authenticated HTTP request using the identity stored
     * under [KEYSTORE_ALIAS] to present a client certificate, and the
     * platform's normal trust store to validate the SERVER's certificate
     * (the SOAR backend's own TLS cert is a regular publicly-trusted one —
     * [caCertPem] stored above is the issuer of THIS DEVICE's client cert,
     * an unrelated concern from server trust, so it plays no role here).
     *
     * Deliberately builds a fresh SSLContext scoped to this one request
     * rather than installing it as the process-wide default
     * (HttpsURLConnection.setDefaultSSLSocketFactory) — the plain
     * (non-mTLS) enrollment POST in mtls_identity.dart's enroll() must never
     * present a client certificate, and a global override would leak into
     * that call too.
     *
     * Uses raw HttpsURLConnection rather than adding OkHttp as a new
     * dependency — this repo has stayed deliberately dependency-light
     * (bcpkix-jdk18on for CSR signing is the one exception, and only
     * because there's no CSR-building API in the Android SDK itself).
     */
    private fun mtlsRequest(
        method: String,
        urlString: String,
        headers: Map<String, String>,
        body: String?
    ): Map<String, Any?> {
        val ks = keyStore()

        // Same temporary diagnostic as storeCertificate — logs what's
        // actually in the keystore AT REQUEST TIME (not just at the moment
        // it was originally stored, which only happens once per enrollment
        // and wouldn't show up in a later app session's logs otherwise).
        // Remove alongside the logging in storeCertificate once resolved.
        val requestTimeChain = ks.getCertificateChain(KEYSTORE_ALIAS)
        Log.i(LOG_TAG, "mtlsRequest: keystore has ${requestTimeChain?.size ?: 0} certificate(s) for $KEYSTORE_ALIAS at request time")
        requestTimeChain?.forEachIndexed { index, c ->
            if (c is X509Certificate) {
                Log.i(
                    LOG_TAG,
                    "mtlsRequest: chain[$index] subject=${c.subjectX500Principal} " +
                        "issuer=${c.issuerX500Principal} notAfter=${c.notAfter}"
                )
            }
        }

        val keyManagerFactory = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        // Password is ignored for AndroidKeyStore-backed entries (there's no
        // keystore-wide password concept the way there is for a JKS/PKCS12
        // file) — null is the documented correct value here.
        keyManagerFactory.init(ks, null)

        val trustManagerFactory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        trustManagerFactory.init(null as KeyStore?)

        // Wrap the default X509KeyManager(s) to force chooseClientAlias to
        // always return KEYSTORE_ALIAS — found necessary against a real
        // deployment: Android's built-in X509KeyManager backed by
        // AndroidKeyStore has a well-documented history of returning null
        // from chooseClientAlias during a live TLS handshake even when the
        // keystore genuinely contains a single, valid, matching entry (the
        // server ends up seeing $ssl_client_verify == NONE — "no certificate
        // was ever offered" — not a rejected/invalid one). Since this
        // keystore only ever holds the one `es.applivery.soar.mtls` alias
        // (never ambiguous which identity to present), forcing the alias
        // sidesteps whatever's going wrong in that selection logic entirely
        // rather than trying to root-cause it further. getCertificateChain/
        // getPrivateKey/etc. still delegate to the real KeyManager, which
        // already works correctly (confirmed — enrollment's own use of this
        // same keystore has been verified end-to-end).
        val keyManagers = keyManagerFactory.keyManagers.map { keyManager ->
            if (keyManager is X509ExtendedKeyManager) {
                object : X509ExtendedKeyManager() {
                    override fun chooseClientAlias(
                        keyType: Array<out String>?,
                        issuers: Array<out Principal>?,
                        socket: Socket?
                    ): String = KEYSTORE_ALIAS

                    override fun chooseEngineClientAlias(
                        keyType: Array<out String>?,
                        issuers: Array<out Principal>?,
                        engine: SSLEngine?
                    ): String = KEYSTORE_ALIAS

                    override fun getCertificateChain(alias: String?): Array<X509Certificate>? =
                        keyManager.getCertificateChain(alias)

                    override fun getPrivateKey(alias: String?): PrivateKey? =
                        keyManager.getPrivateKey(alias)

                    override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? =
                        keyManager.getClientAliases(keyType, issuers)

                    override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?): Array<String>? =
                        keyManager.getServerAliases(keyType, issuers)

                    override fun chooseServerAlias(
                        keyType: String?,
                        issuers: Array<out Principal>?,
                        socket: Socket?
                    ): String? = keyManager.chooseServerAlias(keyType, issuers, socket)
                }
            } else {
                keyManager
            }
        }.toTypedArray<KeyManager>()

        // Generic "TLS" (negotiates whatever version client and server both
        // support), not a pinned "TLSv1.2" — reverted after testing showed
        // pinning to TLS 1.2 didn't fix the original $ssl_client_verify ==
        // NONE symptom (the alias-forcing wrapper above was the actual fix
        // for that) and pinning may itself have been the cause of a
        // DIFFERENT failure ("Read error: ssl=... I/O error during system
        // call") observed once both changes were combined — never isolated
        // and tested TLS 1.2 alone, so it's the more likely regression of
        // the two. If nginx's TLS 1.3 post-handshake-client-auth gap (see
        // this file's own earlier investigation, still a real documented
        // nginx caveat) turns out to matter here after all, revisit with the
        // two changes isolated one at a time rather than stacked.
        val sslContext = SSLContext.getInstance("TLS")
        sslContext.init(keyManagers, trustManagerFactory.trustManagers, null)

        val connection = URL(urlString).openConnection() as HttpsURLConnection
        connection.sslSocketFactory = sslContext.socketFactory
        connection.requestMethod = method
        connection.connectTimeout = 30_000
        connection.readTimeout = 30_000
        headers.forEach { (key, value) -> connection.setRequestProperty(key, value) }

        if (body != null) {
            connection.doOutput = true
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        }

        val statusCode = connection.responseCode
        val stream = if (statusCode in 200..299) connection.inputStream else connection.errorStream
        val responseBody = stream?.bufferedReader()?.use { it.readText() } ?: ""

        return mapOf("statusCode" to statusCode, "body" to responseBody)
    }

    /** RFC 7468-style PEM: 64-char base64 lines, explicit BEGIN/END labels. */
    private fun toPem(der: ByteArray, label: String): String {
        val base64 = Base64.encodeToString(der, Base64.NO_WRAP)
        val wrapped = base64.chunked(64).joinToString("\n")
        return "-----BEGIN $label-----\n$wrapped\n-----END $label-----\n"
    }
}
