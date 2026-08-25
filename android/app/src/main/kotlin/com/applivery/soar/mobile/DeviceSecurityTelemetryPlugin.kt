package com.applivery.soar.mobile

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Device-security telemetry the SOAR Mobile Agent self-reports back to SOAR
 * (POST /api/device-data/report, via lib/api/device_report_client.dart) —
 * the Android counterpart to ios/Runner/DeviceSecurityTelemetryPlugin.swift.
 * See that file's doc comment for why this is a separate concept/channel
 * from RootDetectorPlugin.kt's compromise-detection signals.
 *
 * Empty for now — Android's own security-posture signals (Security Provider
 * freshness, KeyStore hardware attestation level, Play Integrity verdict)
 * are a separate roadmap phase, landing here as additional map entries
 * without touching the channel contract or the Dart/report-loop side at
 * all. Kept as its own plugin now (rather than added later) so the
 * report-loop wiring on both platforms is built and tested against a real,
 * if currently minimal, channel on both sides at once.
 */
class DeviceSecurityTelemetryPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val METHOD_CHANNEL = "es.applivery.soar/device_telemetry"
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
        when (call.method) {
            "collect" -> result.success(emptyMap<String, Any>())
            else -> result.notImplemented()
        }
    }
}
