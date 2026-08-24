package com.applivery.soar.mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    // App-embedded platform channels — see ManagedConfigPlugin.kt and
    // RootDetectorPlugin.kt. Registered by hand here rather than via
    // GeneratedPluginRegistrant since these aren't real pubspec-declared
    // plugins, the same pattern AppDelegate.swift uses on iOS.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(ManagedConfigPlugin())
        flutterEngine.plugins.add(RootDetectorPlugin())
    }
}
