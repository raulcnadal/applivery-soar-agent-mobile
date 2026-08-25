package com.applivery.soar.mobile

import android.content.Context
import android.content.SharedPreferences
import com.google.android.gms.tasks.Tasks
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityTokenRequest
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

/**
 * Google Play Integrity API — mobile telemetry roadmap Phase 3, Android-only
 * (there's no iOS counterpart; Play Integrity is a Play Services concept).
 * Makes the on-device "Classic API request" (developer.android.com/google/
 * play/integrity/classic) with a server-issued nonce +
 * cloudProjectNumber (lib/api/play_integrity_client.dart fetches both from
 * GET /api/device-data/play-integrity/nonce first) and hands the raw,
 * still-encrypted/signed token straight back to Dart — this plugin never
 * decodes it. Decoding happens exclusively server-side
 * (playIntegrity.service.ts's verifyAndDecodeToken): Google's own guidance
 * is that a rooted device can hook the app binary and fake a passing
 * verdict, so nothing decoded on-device could ever be trusted anyway.
 *
 * Throttled independently of the report cycle's own interval: Google's
 * guidance for Classic requests is to call them judiciously rather than on
 * every single check, since (unlike Standard's prepare/request split) each
 * Classic call is a full round-trip to Play. A SharedPreferences timestamp
 * enforces MIN_INTERVAL_MS between real requests; a call inside the window
 * fails fast with "THROTTLED" rather than silently making a Play Integrity
 * request the roadmap doesn't want yet.
 */
class PlayIntegrityPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val METHOD_CHANNEL = "es.applivery.soar/play_integrity"
        private const val PREFS_NAME = "es.applivery.soar.play_integrity"
        private const val PREF_LAST_REQUEST_AT = "last_request_at_millis"

        // Play Integrity Classic requests are meant to be infrequent — this
        // mirrors the report cycle's own cadence being much shorter than
        // "once per device lifecycle" while still keeping well clear of any
        // per-project quota concerns. Not user-configurable; revisit if
        // Google's own guidance changes.
        private val MIN_INTERVAL_MS = TimeUnit.HOURS.toMillis(6)

        // Play Integrity's own documented upper bound for how long a request
        // may reasonably take before something's wrong.
        private val REQUEST_TIMEOUT_SECONDS = 10L
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
            "requestToken" -> {
                val nonce = call.argument<String>("nonce")
                val cloudProjectNumber = call.argument<String>("cloudProjectNumber")
                if (nonce.isNullOrEmpty() || cloudProjectNumber.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "nonce and cloudProjectNumber are both required", null)
                    return
                }
                val context = applicationContext
                if (context == null) {
                    result.error("NO_CONTEXT", "Plugin not attached to an Android context", null)
                    return
                }
                if (isThrottled(context)) {
                    result.error("THROTTLED", "A Play Integrity token was already requested recently — skipping this cycle.", null)
                    return
                }
                scope.launch {
                    try {
                        val token = withContext(Dispatchers.IO) {
                            requestToken(context, nonce, cloudProjectNumber)
                        }
                        markRequested(context)
                        result.success(token)
                    } catch (e: Exception) {
                        result.error("REQUEST_FAILED", e.message ?: e.toString(), null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun isThrottled(context: Context): Boolean {
        val lastRequestAt = prefs(context).getLong(PREF_LAST_REQUEST_AT, 0L)
        return System.currentTimeMillis() - lastRequestAt < MIN_INTERVAL_MS
    }

    private fun markRequested(context: Context) {
        prefs(context).edit().putLong(PREF_LAST_REQUEST_AT, System.currentTimeMillis()).apply()
    }

    /**
     * The actual Classic API call — `IntegrityManagerFactory.create(context)`
     * (not `StandardIntegrityManager`: only Classic supports the offline/
     * local-decryption path the admin asked for, per playIntegrity.service.ts's
     * own doc comment). `Tasks.await` blocks the calling thread, which is
     * safe here since this whole function already runs on Dispatchers.IO —
     * same pattern DeviceSecurityTelemetryPlugin.kt uses for
     * ProviderInstaller.installIfNeeded.
     */
    private fun requestToken(context: Context, nonce: String, cloudProjectNumber: String): String {
        val integrityManager = IntegrityManagerFactory.create(context)
        val request = IntegrityTokenRequest.builder()
            .setNonce(nonce)
            .setCloudProjectNumber(cloudProjectNumber.toLong())
            .build()
        val task = integrityManager.requestIntegrityToken(request)
        val response = Tasks.await(task, REQUEST_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        return response.token()
    }
}
