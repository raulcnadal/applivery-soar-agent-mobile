import Flutter
import Foundation

/// Bridges iOS's Managed App Configuration — the `com.apple.configuration.managed`
/// dictionary MDM pushes into this app's UserDefaults once Applivery UEM
/// assigns it — to Dart. See android/app/src/main/kotlin/.../ManagedConfigPlugin.kt
/// for the Android equivalent (Android Enterprise App Restrictions via
/// RestrictionsManager) and ARCHITECTURE.md for the shared field schema both
/// platforms decode into the same Dart ManagedConfig model
/// (lib/config/managed_config.dart).
///
/// Not a real federated Flutter plugin (no pubspec entry, no
/// ios/*.podspec) — registered by hand from AppDelegate.swift, the same
/// app-embedded-platform-code pattern MainActivity.kt uses on Android. A
/// real plugin package would be overkill for two small, app-specific
/// channels with no reuse case outside this app.
final class ManagedConfigPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private static let managedConfigKey = "com.apple.configuration.managed"
    private static let methodChannelName = "es.applivery.soar/managed_config"
    private static let eventChannelName = "es.applivery.soar/managed_config_stream"

    private var eventSink: FlutterEventSink?
    private var observer: NSObjectProtocol?

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = ManagedConfigPlugin()

        let methodChannel = FlutterMethodChannel(
            name: methodChannelName,
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(
            name: eventChannelName,
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(instance)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getManagedConfig":
            result(Self.readManagedConfig())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        // UserDefaults.didChangeNotification fires on ANY defaults write,
        // not just a managed-config push — UIKit has no narrower "managed
        // config changed" notification to hook. Every fire re-reads the same
        // key from scratch rather than trusting the notification's own
        // payload (it carries none anyway); the Dart side is responsible for
        // deciding whether anything it cares about actually changed.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.eventSink?(Self.readManagedConfig())
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        eventSink = nil
        return nil
    }

    private static func readManagedConfig() -> [String: Any] {
        return UserDefaults.standard.dictionary(forKey: managedConfigKey) ?? [:]
    }
}
