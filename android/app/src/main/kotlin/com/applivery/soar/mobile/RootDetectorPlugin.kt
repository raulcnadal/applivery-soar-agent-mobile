package com.applivery.soar.mobile

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Debug
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Heuristic root detection. See ios/Runner/JailbreakDetector.swift for the
 * iOS equivalent and the same "signals, not a single boolean" contract:
 * useful both for the compliance status screen (show *why*, not just a
 * red/green dot) and for feeding a selfReported.customCheckResults-shaped
 * payload to the SOAR backend later.
 *
 * Best-effort, not tamper-proof — same caveat class as the Windows/macOS
 * agents' mutual-watchdog anti-tampering (their own ARCHITECTURE.md §2): a
 * deterrent against a casual/default root, not a guarantee against a
 * determined, root-hiding attacker. Magisk's own Zygisk/DenyList features
 * exist specifically to defeat exactly this kind of check; this raises the
 * bar, it isn't a security boundary on its own.
 *
 * Mobile telemetry roadmap Phase 4: expanded from the original 4-check
 * foundation to the layered approach described in the reference article
 * ("Android security for dummies: Root detection") — Basic/File/Package/
 * Process detection layers all implemented below. The article's 5th layer,
 * native (JNI/C) checks via a Frida-detection .so, is DELIBERATELY not
 * implemented here: this app has no NDK build set up, adding one can't be
 * compiled or verified in this environment, and the user's own roadmap
 * message explicitly deferred "a RASP library" (which is what that native
 * layer really is, in miniature) to a later phase. Everything at the
 * Java/Kotlin level the article describes is covered.
 *
 * `isCompromised`/`signals` is unchanged as the local-diagnostics contract
 * (compliance_screen.dart's Diagnostics drawer); as of Phase 4,
 * `device_report_client.dart` ALSO calls this same channel and folds
 * `isCompromised` into the report payload as `deviceRootedOrJailbroken` —
 * see that file's own doc comment.
 */
class RootDetectorPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val METHOD_CHANNEL = "es.applivery.soar/root_detector"

        private val SU_PATHS = listOf(
            "/system/bin/su",
            "/system/xbin/su",
            "/sbin/su",
            "/system/su",
            "/system/bin/.ext/.su",
            "/system/usr/we-need-root/su-backup",
            "/system/xbin/daemonsu",
            "/data/adb/magisk",
            "/data/adb/ksu", // KernelSU
            "/system/app/Superuser.apk",
            "/data/local/xbin/su",
            "/data/local/bin/su",
            "/system/sd/xbin/su",
            "/system/bin/failsafe/su",
            "/data/local/su",
        )

        private val ROOT_APP_PACKAGES = listOf(
            "com.topjohnwu.magisk",
            "eu.chainfire.supersu",
            "com.noshufou.android.su",
            "com.koushikdutta.superuser",
            "com.zachspong.temprootremovejb",
            "com.ramdroid.appquarantine",
            "me.weishu.kernelsu",
            "com.thirdparty.superuser",
            "com.yellowes.su",
        )

        // Frida's default listening port (frida-server) — a device with a
        // Frida instrumentation server reachable on localhost is a strong
        // reverse-engineering/tampering signal regardless of root status.
        private const val FRIDA_DEFAULT_PORT = 27042
        private val FRIDA_FILE_PATHS = listOf(
            "/data/local/tmp/frida-server",
            "/data/local/tmp/re.frida.server",
        )

        // Loading this class only succeeds when the Xposed framework (or a
        // compatible fork, e.g. LSPosed) is actually active in this
        // process — a stock, unhooked app can never resolve it.
        private const val XPOSED_BRIDGE_CLASS = "de.robv.android.xposed.XposedBridge"

        private val SUSPICIOUS_SYSTEM_PROPERTIES = mapOf(
            "ro.debuggable" to "1",
            "ro.secure" to "0",
            "service.adb.root" to "1",
        )
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
            // Phase 4 added a real network call (isFridaPortOpen's socket
            // probe) alongside the pre-existing filesystem checks, so this
            // now runs on Dispatchers.IO rather than synchronously on the
            // platform-channel (main) thread — a raw Socket().connect() on
            // the main thread throws NetworkOnMainThreadException on every
            // stock Android build. Same pattern
            // DeviceSecurityTelemetryPlugin.kt already established for its
            // own IO-bound checks.
            "checkIntegrity" -> {
                scope.launch {
                    val checkResult = withContext(Dispatchers.IO) { runChecks() }
                    result.success(checkResult)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun runChecks(): Map<String, Any> {
        val signals = mutableListOf<String>()

        // -- Basic detection --
        if (isAppDebuggable()) signals.add("app_debuggable_flag_set")
        if (hasTestKeysBuildTag()) signals.add("build_tags_test_keys")
        if (isLikelyEmulator()) signals.add("running_on_emulator")

        // -- File detection --
        val foundSuPaths = SU_PATHS.filter { File(it).exists() }
        if (foundSuPaths.isNotEmpty()) {
            signals.add("su_binary_present:${foundSuPaths.joinToString(",")}")
        }
        if (systemPartitionWritable()) signals.add("system_partition_writable")
        if (FRIDA_FILE_PATHS.any { File(it).exists() }) signals.add("frida_server_file_present")

        // -- Package detection --
        if (rootAppInstalled()) signals.add("root_management_app_installed")
        if (isXposedPresent()) signals.add("xposed_framework_detected")

        // -- Process / runtime detection --
        if (detectDebugger()) signals.add("debugger_connected")
        if (detectTimingAnomaly()) signals.add("timing_anomaly_detected")
        val badProperties = suspiciousSystemProperties()
        if (badProperties.isNotEmpty()) signals.add("suspicious_system_properties:${badProperties.joinToString(",")}")
        if (isFridaPortOpen()) signals.add("frida_port_open")

        // -- Native (JNI/C) detection --
        // Deliberately not implemented — see this class's own doc comment.

        return mapOf(
            "isCompromised" to signals.isNotEmpty(),
            "signals" to signals,
        )
    }

    private fun rootAppInstalled(): Boolean {
        val pm = applicationContext?.packageManager ?: return false
        return ROOT_APP_PACKAGES.any { pkg ->
            try {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(pkg, 0)
                true
            } catch (e: PackageManager.NameNotFoundException) {
                false
            }
        }
    }

    private fun hasTestKeysBuildTag(): Boolean {
        return Build.TAGS?.contains("test-keys") == true
    }

    /**
     * A stock, non-rooted device's /system partition is never writable by a
     * regular app — attempting to create a file there and having it succeed
     * is itself the signal, independent of whether a known su binary or
     * root-management app is also present (covers a root method that hides
     * the more commonly-checked-for artifacts above).
     */
    private fun systemPartitionWritable(): Boolean {
        return try {
            val probe = File("/system/.applivery_soar_root_probe_${System.currentTimeMillis()}")
            val created = probe.createNewFile()
            if (created) probe.delete()
            created
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Whether THIS app's own APK was built/signed as debuggable
     * (`android:debuggable="true"`, normally only true for a debug build) —
     * a signal distinct from root: a release-signed app should never carry
     * this flag, so seeing it set on what claims to be a production install
     * suggests a repackaged/resigned APK sideloaded onto the device.
     */
    private fun isAppDebuggable(): Boolean {
        val context = applicationContext ?: return false
        return (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    }

    /** `Debug.isDebuggerConnected()`/`waitingForDebugger()` — a live JDWP debugger attached to this process right now. */
    private fun detectDebugger(): Boolean {
        return try {
            Debug.isDebuggerConnected() || Debug.waitingForDebugger()
        } catch (e: Throwable) {
            false
        }
    }

    /**
     * Timing-based anti-debug: a tight, side-effect-free loop should
     * complete in a small, predictable amount of thread CPU time; a
     * debugger single-stepping or a tracer intercepting this thread
     * inflates that time well past a normal-execution threshold. The exact
     * threshold (10ms of thread CPU time for one million empty iterations)
     * mirrors the reference article's own implementation — deliberately
     * conservative to avoid false positives on slow/throttled devices.
     */
    private fun detectTimingAnomaly(): Boolean {
        return try {
            val start = Debug.threadCpuTimeNanos()
            var i = 0
            while (i < 1_000_000) i++
            val elapsed = Debug.threadCpuTimeNanos() - start
            elapsed >= 10_000_000L
        } catch (e: Throwable) {
            false
        }
    }

    /**
     * `android.os.SystemProperties` is a hidden (`@hide`) API with no public
     * SDK entry point, so this goes through reflection — the standard,
     * widely-used way apps read system properties without an NDK
     * dependency. Any reflection failure (a future Android version removing
     * or relocating this class) collapses to "couldn't check", not a false
     * positive.
     */
    private fun getSystemProperty(name: String): String? {
        return try {
            val clazz = Class.forName("android.os.SystemProperties")
            val method = clazz.getMethod("get", String::class.java)
            method.invoke(null, name) as? String
        } catch (e: Throwable) {
            null
        }
    }

    private fun suspiciousSystemProperties(): List<String> {
        return SUSPICIOUS_SYSTEM_PROPERTIES.entries
            .filter { (name, badValue) -> getSystemProperty(name) == badValue }
            .map { (name, _) -> name }
    }

    /** Resolvable only when the Xposed framework (or a compatible fork like LSPosed) is actually hooking this process. */
    private fun isXposedPresent(): Boolean {
        return try {
            Class.forName(XPOSED_BRIDGE_CLASS)
            true
        } catch (e: ClassNotFoundException) {
            false
        } catch (e: Throwable) {
            false
        }
    }

    /**
     * A short-timeout TCP probe against Frida's default listening port —
     * frida-server binds this port on the device itself (not a network
     * service), so a successful local connection is a strong instrumentation
     * signal. 200ms timeout keeps a clean device's report cycle from
     * stalling on this check.
     */
    private fun isFridaPortOpen(): Boolean {
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", FRIDA_DEFAULT_PORT), 200)
                true
            }
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Coarse emulator/CI-runner detection — a genuinely enrolled fleet
     * device should never be an SDK emulator or Genymotion instance. Folded
     * into `isCompromised` the same as every other signal here: on its own
     * it doesn't prove malicious intent, but a fleet device reporting as an
     * emulator is itself a fleet-hygiene problem worth flagging, not just a
     * root/tamper corroborator.
     */
    private fun isLikelyEmulator(): Boolean {
        val fingerprint = Build.FINGERPRINT?.lowercase() ?: ""
        val model = Build.MODEL?.lowercase() ?: ""
        val manufacturer = Build.MANUFACTURER?.lowercase() ?: ""
        val product = Build.PRODUCT?.lowercase() ?: ""
        return fingerprint.startsWith("generic") ||
            fingerprint.contains("vbox") ||
            model.contains("google_sdk") ||
            model.contains("emulator") ||
            model.contains("android sdk built for") ||
            manufacturer.contains("genymotion") ||
            product.contains("sdk") ||
            product.contains("vbox")
    }
}
