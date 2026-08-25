import Flutter
import Foundation
import Security

/// Device-security telemetry the SOAR Mobile Agent self-reports back to
/// SOAR (POST /api/device-data/report, via lib/api/device_report_client.dart)
/// — distinct from JailbreakDetector.swift's compromise-detection signals
/// (which stay purely local/diagnostic today, see that file's own doc
/// comment). This channel's job is "what should the compliance engine know
/// about this device's security posture", the same role Windows/macOS's
/// self-report agents fill via report-security-attributes.ps1/.sh.
///
/// `devicePasscodeSet` is the first (and, for iOS specifically, the only
/// meaningful) signal here: iOS has no public API to directly query "is
/// Data Protection encryption enabled" the way BitLocker/FileVault expose a
/// status flag, because there's nothing to separately enable — Data
/// Protection is automatically active for every app the moment (and only
/// once) a device passcode is set. A device with no passcode has no
/// encryption-at-rest either, so the standard technique (documented widely,
/// e.g. Apple's own Keychain Services guidance on kSecAttrAccessible
/// values) is to attempt writing a throwaway Keychain item with
/// `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` — the OS itself refuses
/// that write with `errSecNotAvailable` (extended by `errSecAccessError`)
/// when no passcode is configured, since the passcode-derived key needed to
/// protect that class of item doesn't exist yet. A successful write is
/// therefore a reliable, first-party signal that a passcode is set — no
/// heuristics, no filesystem probing, no private API.
final class DeviceSecurityTelemetryPlugin: NSObject, FlutterPlugin {
    private static let channelName = "es.applivery.soar/device_telemetry"
    private static let probeAccount = "es.applivery.soar.passcode_probe"

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = DeviceSecurityTelemetryPlugin()
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "collect":
            result(Self.collectTelemetry())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static func collectTelemetry() -> [String: Any] {
        return [
            "devicePasscodeSet": isPasscodeSet(),
        ]
    }

    /// Deletes any stale probe item first (a previous run that crashed
    /// before cleanup would otherwise make SecItemAdd return
    /// errSecDuplicateItem, which says nothing about passcode status),
    /// attempts the passcode-gated write, then always cleans the probe item
    /// back up regardless of outcome — this never leaves real data behind,
    /// it's purely a capability probe.
    private static func isPasscodeSet() -> Bool {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: probeAccount,
            kSecAttrService as String: "es.applivery.soar.telemetry",
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = "1".data(using: .utf8)!
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        SecItemDelete(baseQuery as CFDictionary)

        return status == errSecSuccess
    }
}
