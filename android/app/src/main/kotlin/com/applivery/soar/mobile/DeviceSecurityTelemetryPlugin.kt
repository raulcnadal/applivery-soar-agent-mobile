package com.applivery.soar.mobile

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import com.google.android.gms.common.GooglePlayServicesNotAvailableException
import com.google.android.gms.common.GooglePlayServicesRepairableException
import com.google.android.gms.security.ProviderInstaller
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.SecureRandom

/**
 * Device-security telemetry the SOAR Mobile Agent self-reports back to SOAR
 * (POST /api/device-data/report, via lib/api/device_report_client.dart) —
 * the Android counterpart to ios/Runner/DeviceSecurityTelemetryPlugin.swift.
 * See that file's doc comment for why this is a separate concept/channel
 * from RootDetectorPlugin.kt's compromise-detection signals.
 *
 * Phase 2 of the device-security-telemetry roadmap (Phase 1 was iOS-only —
 * see that plugin's doc comment): adds Android's first two real signals.
 * Both checks touch the filesystem/network/keystore, so `collect` runs them
 * on Dispatchers.IO via a coroutine rather than blocking Flutter's
 * platform-channel thread — same reasoning MtlsIdentityPlugin already
 * documents for its own mtlsRequest handler.
 */
class DeviceSecurityTelemetryPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val METHOD_CHANNEL = "es.applivery.soar/device_telemetry"

        // A throwaway alias, never used for any real key material — purely a
        // probe to read back how the OS actually protected a freshly
        // generated key. Deleted (both before and after generation) so
        // repeated report cycles never accumulate stale keystore entries.
        private const val ATTESTATION_KEY_ALIAS = "es.applivery.soar.attestation_probe"
    }

    private var applicationContext: Context? = null
    private var methodChannel: MethodChannel? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        applicationContext = null
        scope.cancel()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "collect" -> {
                scope.launch {
                    val telemetry = withContext(Dispatchers.IO) { collectTelemetry() }
                    result.success(telemetry)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun collectTelemetry(): Map<String, Any> {
        return mapOf(
            "securityProviderUpToDate" to checkSecurityProviderUpToDate(),
            "keystoreAttestationSecurityLevel" to checkKeystoreAttestationSecurityLevel(),
        )
    }

    /**
     * ProviderInstaller's own documentation: `installIfNeeded` is meant to
     * be called off the UI thread (satisfied — this whole method already
     * runs on Dispatchers.IO, see onMethodCall above); a normal return means
     * the security provider is current. Both documented exceptions, and any
     * other unexpected failure (some OEM builds throw plain
     * IllegalStateException with a broken/absent Play services install),
     * collapse into "not confirmed up to date" — this is a single boolean
     * telemetry signal, not a place to retry or prompt the user from a
     * report cycle.
     */
    private fun checkSecurityProviderUpToDate(): Boolean {
        val context = applicationContext ?: return false
        return try {
            ProviderInstaller.installIfNeeded(context)
            true
        } catch (e: GooglePlayServicesRepairableException) {
            false
        } catch (e: GooglePlayServicesNotAvailableException) {
            false
        } catch (e: Throwable) {
            false
        }
    }

    /**
     * Generates a throwaway EC key inside AndroidKeyStore with an
     * attestation challenge, then reads back how the OS actually protected
     * it: `KeyInfo.getSecurityLevel()` (API 31+, an enum: StrongBox/TEE/
     * Software/Unknown) or the coarser `isInsideSecureHardware()` boolean on
     * older API levels where that enum doesn't exist. This is a plain
     * public-SDK read-back of the OS's own answer — no attestation
     * certificate parsing, no server round-trip, and (unlike Play Integrity
     * in Phase 3) nothing that needs server-side verification, since the
     * question here is "what hardware does THIS OS claim to have used",
     * which the platform itself is the authority on.
     */
    private fun checkKeystoreAttestationSecurityLevel(): String {
        val keyStore = try {
            KeyStore.getInstance("AndroidKeyStore").also { it.load(null) }
        } catch (e: Throwable) {
            return "Unavailable"
        }

        return try {
            keyStore.deleteEntry(ATTESTATION_KEY_ALIAS)

            val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            val challenge = ByteArray(16).also { SecureRandom().nextBytes(it) }
            val spec = KeyGenParameterSpec.Builder(
                ATTESTATION_KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
            )
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setAttestationChallenge(challenge)
                .build()
            generator.initialize(spec)
            val keyPair = generator.generateKeyPair()

            val factory = KeyFactory.getInstance(keyPair.private.algorithm, "AndroidKeyStore")
            val keyInfo = factory.getKeySpec(keyPair.private, KeyInfo::class.java)

            val level = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                when (keyInfo.securityLevel) {
                    KeyProperties.SECURITY_LEVEL_STRONGBOX -> "StrongBox"
                    KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "TrustedEnvironment"
                    KeyProperties.SECURITY_LEVEL_SOFTWARE -> "Software"
                    else -> "Unknown"
                }
            } else {
                // Pre-API 31: only the coarser boolean is available — no way
                // to distinguish StrongBox from a plain TEE, just
                // "some secure hardware" vs. "software only".
                if (keyInfo.isInsideSecureHardware) "TrustedEnvironment" else "Software"
            }

            level
        } catch (e: Throwable) {
            "Unavailable"
        } finally {
            // Always clean up the probe key, success or failure — this is
            // never meant to be a persistent app key.
            try {
                keyStore.deleteEntry(ATTESTATION_KEY_ALIAS)
            } catch (e: Throwable) {
                // Best-effort cleanup only.
            }
        }
    }
}
