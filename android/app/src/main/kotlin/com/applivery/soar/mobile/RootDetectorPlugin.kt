package com.applivery.soar.mobile

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

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
        )

        private val ROOT_APP_PACKAGES = listOf(
            "com.topjohnwu.magisk",
            "eu.chainfire.supersu",
            "com.noshufou.android.su",
            "com.koushikdutta.superuser",
            "com.zachspong.temprootremovejb",
            "com.ramdroid.appquarantine",
            "me.weishu.kernelsu",
        )
    }

    private var applicationContext: Context? = null
    private var methodChannel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        applicationContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkIntegrity" -> result.success(runChecks())
            else -> result.notImplemented()
        }
    }

    private fun runChecks(): Map<String, Any> {
        val signals = mutableListOf<String>()

        val foundSuPaths = SU_PATHS.filter { File(it).exists() }
        if (foundSuPaths.isNotEmpty()) {
            signals.add("su_binary_present:${foundSuPaths.joinToString(",")}")
        }
        if (rootAppInstalled()) signals.add("root_management_app_installed")
        if (hasTestKeysBuildTag()) signals.add("build_tags_test_keys")
        if (systemPartitionWritable()) signals.add("system_partition_writable")

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
}
