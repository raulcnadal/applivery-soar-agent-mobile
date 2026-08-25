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
 * Heuristic root/tamper detection — the SOAR Mobile Agent's in-house RASP
 * (Runtime Application Self-Protection) foundation. See
 * ios/Runner/JailbreakDetector.swift for the iOS equivalent and the same
 * "signals bucketed into 3 categories, not a single boolean" contract:
 * useful both for the compliance status screen (show *why*, not just a
 * red/green dot) and for feeding device_report_client.dart's report
 * payload.
 *
 * Best-effort, not tamper-proof — same caveat class as the Windows/macOS
 * agents' mutual-watchdog anti-tampering (their own ARCHITECTURE.md §2): a
 * deterrent against a casual/default root, not a guarantee against a
 * determined, root-hiding attacker. Magisk's own Zygisk/DenyList features
 * exist specifically to defeat exactly this kind of check; this raises the
 * bar, it isn't a security boundary on its own.
 *
 * Mobile telemetry roadmap Phase 4 expanded this from a 4-check foundation
 * to a layered approach (Basic/File/Package/Process detection). Phase 5
 * (this pass) is the in-house RASP roadmap: rather than paying for
 * freeRASP's highest tier (needed to control where its telemetry is
 * reported — a non-starter for a self-hosted SOAR that must keep this data
 * in its own pipeline), this class absorbs the equivalent detection
 * techniques directly, and — new this phase — buckets every signal into
 * three named categories (`isRootedOrJailbroken`/`isDebuggerAttached`/
 * `isHookingFrameworkDetected`) instead of one merged `isCompromised`
 * boolean, so each can become its own Compliance Policy condition
 * (complianceFields.ts's SELF_REPORTED_ATTRIBUTE_CATALOG) rather than
 * conflating "this device is rooted" with "someone has a debugger attached
 * to it right now" — genuinely different risk profiles.
 *
 * Two new Phase 5 techniques, both native-adjacent (no NDK needed — Linux
 * exposes both through plain files any JVM can read):
 * - `checkTracerPid()`: `/proc/self/status`'s `TracerPid` field is the
 *   kernel's own record of which process (if any) has attached via
 *   ptrace() to this one — catches gdb/lldb-server/Frida's own
 *   ptrace-based attach path, not just a JDWP debugger the way
 *   `Debug.isDebuggerConnected()` alone would.
 * - `checkProcMapsForHookingArtifacts()`: `/proc/self/maps` lists every
 *   memory-mapped file in this process, including any injected .so a
 *   hooking framework loaded — a process can't hide a mapped library from
 *   its own maps file the way it might rename/hide a file on disk.
 *
 * The article's original 5th layer — actual NDK/JNI-compiled native
 * checks — remains deliberately unimplemented: still no NDK build in this
 * app, and both new checks above already reach the same category of
 * information (the kernel's process/memory bookkeeping) without one.
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

        // Substrings looked for in /proc/self/maps' mapped-file paths —
        // any hooking/instrumentation framework's injected library shows up
        // here regardless of what directory it was loaded from.
        private val PROC_MAPS_HOOKING_MARKERS = listOf("frida", "gadget", "xposed", "substrate", "magisk")

        // Loading this class only succeeds when the Xposed framework (or a
        // compatible fork, e.g. LSPosed) is actually active in this
        // process — a stock, unhooked app can never resolve it.
        private const val XPOSED_BRIDGE_CLASS = "de.robv.android.xposed.XposedBridge"

        // Build-level indicators of a non-production/eng Android image —
        // grouped with root/compromise signals (not "debugger attached")
        // since these describe the OS BUILD's own posture, not an active
        // debugging session against this specific process right now.
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
            // A real network call (isFridaPortOpen's socket probe) alongside
            // filesystem/proc reads, so this runs on Dispatchers.IO rather
            // than synchronously on the platform-channel (main) thread — a
            // raw Socket().connect() on the main thread throws
            // NetworkOnMainThreadException on every stock Android build.
            // Same pattern DeviceSecurityTelemetryPlugin.kt already
            // established for its own IO-bound checks.
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
        val rootedSignals = mutableListOf<String>()
        val debuggerSignals = mutableListOf<String>()
        val hookingSignals = mutableListOf<String>()

        // -- Rooted / compromised-build signals --
        if (isAppDebuggable()) rootedSignals.add("app_debuggable_flag_set")
        if (hasTestKeysBuildTag()) rootedSignals.add("build_tags_test_keys")
        if (isLikelyEmulator()) rootedSignals.add("running_on_emulator")
        val foundSuPaths = SU_PATHS.filter { File(it).exists() }
        if (foundSuPaths.isNotEmpty()) rootedSignals.add("su_binary_present:${foundSuPaths.joinToString(",")}")
        if (systemPartitionWritable()) rootedSignals.add("system_partition_writable")
        if (rootAppInstalled()) rootedSignals.add("root_management_app_installed")
        if (checkSuCommand()) rootedSignals.add("su_command_executable")
        val badProperties = suspiciousSystemProperties()
        if (badProperties.isNotEmpty()) rootedSignals.add("suspicious_system_properties:${badProperties.joinToString(",")}")

        // -- Debugger-attached signals (an active session against THIS process right now) --
        if (detectDebugger()) debuggerSignals.add("debugger_connected")
        if (detectTimingAnomaly()) debuggerSignals.add("timing_anomaly_detected")
        if (checkTracerPid()) debuggerSignals.add("tracer_pid_nonzero")

        // -- Hooking/instrumentation-framework signals --
        if (FRIDA_FILE_PATHS.any { File(it).exists() }) hookingSignals.add("frida_server_file_present")
        if (isXposedPresent()) hookingSignals.add("xposed_framework_detected")
        if (isFridaPortOpen()) hookingSignals.add("frida_port_open")
        val mapsMarkers = checkProcMapsForHookingArtifacts()
        if (mapsMarkers.isNotEmpty()) hookingSignals.add("proc_maps_markers:${mapsMarkers.joinToString(",")}")

        val allSignals = rootedSignals + debuggerSignals + hookingSignals
        return mapOf(
            "isCompromised" to allSignals.isNotEmpty(),
            "signals" to allSignals,
            "isRootedOrJailbroken" to rootedSignals.isNotEmpty(),
            "isDebuggerAttached" to debuggerSignals.isNotEmpty(),
            "isHookingFrameworkDetected" to hookingSignals.isNotEmpty(),
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

    /**
     * Directly attempts `which su` via a shell exec — a complementary check
     * to the static SU_PATHS list above: catches an su binary installed
     * somewhere non-standard (a custom ROM's own PATH, a root method that
     * deliberately avoids the well-known paths) that a fixed path list
     * would miss, at the cost of being unable to distinguish "su isn't
     * installed" from "the shell itself failed to launch" — both collapse
     * to `false` here, which is the safe direction for a false-positive-averse check.
     */
    private fun checkSuCommand(): Boolean {
        return try {
            val process = Runtime.getRuntime().exec(arrayOf("/system/xbin/which", "su"))
            process.inputStream.bufferedReader().use { it.readLine() } != null
        } catch (e: Exception) {
            false
        }
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
     * `/proc/self/status`'s `TracerPid` line is the kernel's own record of
     * which process (if any) is ptrace()-attached to this one — 0 means
     * none. This is a broader, native-level signal than
     * `Debug.isDebuggerConnected()` (which only sees a JDWP/Java debugger):
     * gdb, lldb-server, and Frida's own ptrace-based attach mode all show
     * up here too.
     */
    private fun checkTracerPid(): Boolean {
        return try {
            File("/proc/self/status").useLines { lines ->
                for (line in lines) {
                    if (line.startsWith("TracerPid:")) {
                        val pid = line.substringAfter(":").trim().toIntOrNull() ?: 0
                        return pid != 0
                    }
                }
                false
            }
        } catch (e: Exception) {
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
     * `/proc/self/maps` lists every memory-mapped region in this process,
     * including the path of any mapped file — an injected hooking-framework
     * library shows up here the moment it's loaded, regardless of what
     * directory it was placed in or what it was renamed to try to blend in
     * (unlike the static file-path/package checks above, which only catch
     * KNOWN install locations). Reading this file requires no special
     * permission for a process to read its own maps.
     */
    private fun checkProcMapsForHookingArtifacts(): List<String> {
        return try {
            val found = linkedSetOf<String>()
            File("/proc/self/maps").useLines { lines ->
                for (line in lines) {
                    val lower = line.lowercase()
                    for (marker in PROC_MAPS_HOOKING_MARKERS) {
                        if (lower.contains(marker)) found.add(marker)
                    }
                }
            }
            found.toList()
        } catch (e: Exception) {
            emptyList()
        }
    }

    /**
     * Coarse emulator/CI-runner detection — a genuinely enrolled fleet
     * device should never be an SDK emulator or Genymotion instance. Folded
     * into the rooted/compromised bucket the same as every other signal
     * there: on its own it doesn't prove malicious intent, but a fleet
     * device reporting as an emulator is itself a fleet-hygiene problem
     * worth flagging, not just a root/tamper corroborator.
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
