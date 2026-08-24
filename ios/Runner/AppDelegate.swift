import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // App-embedded platform channels — not real federated Flutter plugins
    // (no pubspec entry), registered by hand the same way MainActivity.kt
    // does on the Android side. See ManagedConfigPlugin.swift /
    // JailbreakDetector.swift.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ManagedConfigPlugin") {
      ManagedConfigPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "JailbreakDetectorPlugin") {
      JailbreakDetectorPlugin.register(with: registrar)
    }
  }
}
