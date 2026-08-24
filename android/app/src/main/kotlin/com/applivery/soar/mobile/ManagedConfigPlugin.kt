package com.applivery.soar.mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.RestrictionsManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Android's Managed Configuration (App Restrictions, pushed by
 * Applivery as this app's EMM via Android Enterprise / Managed Google Play)
 * to Dart. See ios/Runner/ManagedConfigPlugin.swift for the iOS equivalent
 * (UserDefaults' com.apple.configuration.managed key) and ARCHITECTURE.md
 * for the shared field schema both platforms decode into the same Dart
 * ManagedConfig model (lib/config/managed_config.dart).
 *
 * Not a real federated Flutter plugin (no pubspec entry) — registered by
 * hand from MainActivity.kt's configureFlutterEngine, the same
 * app-embedded-platform-code pattern the iOS side uses. A real plugin
 * package would be overkill for two small, app-specific channels with no
 * reuse case outside this app.
 */
class ManagedConfigPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        private const val METHOD_CHANNEL = "es.applivery.soar/managed_config"
        private const val EVENT_CHANNEL = "es.applivery.soar/managed_config_stream"
    }

    private var applicationContext: Context? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var receiver: BroadcastReceiver? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel?.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel?.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        unregisterReceiver()
        applicationContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getManagedConfig" -> result.success(readRestrictions())
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        val context = applicationContext ?: return
        val filter = IntentFilter(Intent.ACTION_APPLICATION_RESTRICTIONS_CHANGED)
        val newReceiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                eventSink?.success(readRestrictions())
            }
        }
        receiver = newReceiver
        // Android 13+ (targeting SDK 33+) requires an explicit exported flag
        // on every dynamically-registered receiver. ACTION_APPLICATION_RESTRICTIONS_CHANGED
        // is a system-server-only broadcast (no other app can send it), so
        // RECEIVER_NOT_EXPORTED is the correct, safer choice — this app never
        // needs to receive it from another app's context.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(newReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(newReceiver, filter)
        }
    }

    override fun onCancel(arguments: Any?) {
        unregisterReceiver()
        eventSink = null
    }

    private fun unregisterReceiver() {
        val context = applicationContext ?: return
        receiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
                // Already unregistered (e.g. onCancel firing after the engine
                // already tore down) — safe to ignore.
            }
        }
        receiver = null
    }

    /**
     * Reads the current App Restrictions bundle and flattens it to a
     * Map<String, Any?> the Dart side can decode directly. RestrictionsManager
     * hands back a raw Bundle (Android's generic key-value container,
     * predating any JSON-friendly restrictions API), which Flutter's
     * StandardMethodCodec can't cross the platform channel as-is.
     */
    private fun readRestrictions(): Map<String, Any?> {
        val context = applicationContext ?: return emptyMap()
        val manager = context.getSystemService(Context.RESTRICTIONS_SERVICE) as? RestrictionsManager
            ?: return emptyMap()
        return bundleToMap(manager.applicationRestrictions)
    }

    private fun bundleToMap(bundle: Bundle): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>()
        for (key in bundle.keySet()) {
            when (val value = bundle.get(key)) {
                is Bundle -> map[key] = bundleToMap(value)
                is Array<*> -> map[key] = value.toList()
                else -> map[key] = value
            }
        }
        return map
    }
}
