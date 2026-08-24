import Flutter
import Foundation
import UIKit

/// Heuristic jailbreak detection. See android/app/src/main/kotlin/.../RootDetectorPlugin.kt
/// for the Android equivalent and the same "signals, not a single boolean"
/// contract: useful both for the compliance status screen (show *why*, not
/// just a red/green dot) and for feeding a
/// selfReported.customCheckResults-shaped payload to the SOAR backend later.
///
/// Best-effort, not tamper-proof — same caveat class as the Windows/macOS
/// agents' mutual-watchdog anti-tampering (their own ARCHITECTURE.md §2): a
/// deterrent against a casual/default jailbreak, not a guarantee against a
/// determined attacker. A jailbreak using a hiding tweak (Shadow, Flex, or
/// rootless jailbreaks' own built-in hiding) can defeat some or all of these
/// checks; this raises the bar, it isn't a security boundary on its own.
final class JailbreakDetectorPlugin: NSObject, FlutterPlugin {
    private static let channelName = "es.applivery.soar/root_detector"

    private static let suspiciousPaths = [
        "/Applications/Cydia.app",
        "/Applications/Sileo.app",
        "/Applications/Zebra.app",
        "/Applications/Installer.app",
        "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/usr/sbin/sshd",
        "/etc/apt",
        "/bin/bash",
        "/private/var/lib/apt",
        "/private/var/lib/cydia",
        "/var/jb", // rootless jailbreaks (Dopamine and similar, post-iOS 15)
    ]

    // Each of these MUST also be listed under LSApplicationQueriesSchemes in
    // Info.plist — canOpenURL(_:) always returns false for an
    // undeclared scheme regardless of whether the handling app is actually
    // installed (iOS 9+ privacy restriction), so omitting that entry here
    // would silently make this check a permanent no-op.
    private static let suspiciousSchemes = ["cydia://", "sileo://", "zbra://", "filza://"]

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = JailbreakDetectorPlugin()
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "checkIntegrity":
            result(Self.runChecks())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static func runChecks() -> [String: Any] {
        #if targetEnvironment(simulator)
        // The Simulator can't be jailbroken, and the sandbox-escape write
        // check in particular behaves differently there than on a real
        // device (the Simulator's filesystem sandboxing model isn't the same
        // as a physical device's) — never let a Simulator-only quirk report
        // as a false positive. Real-device verification is required either
        // way; there's no way to meaningfully exercise this on Simulator.
        return ["isCompromised": false, "signals": ["simulator_checks_skipped"]]
        #else
        var signals: [String] = []

        let foundPaths = suspiciousPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if !foundPaths.isEmpty {
            signals.append("suspicious_path_present:\(foundPaths.joined(separator: ","))")
        }

        if canOpenSuspiciousScheme() {
            signals.append("suspicious_url_scheme_openable")
        }

        if canWriteOutsideSandbox() {
            signals.append("sandbox_escape_write_succeeded")
        }

        return ["isCompromised": !signals.isEmpty, "signals": signals]
        #endif
    }

    private static func canOpenSuspiciousScheme() -> Bool {
        for scheme in suspiciousSchemes {
            if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
                return true
            }
        }
        return false
    }

    private static func canWriteOutsideSandbox() -> Bool {
        let testPath = "/private/jailbreak_test_\(UUID().uuidString).txt"
        do {
            try "test".write(toFile: testPath, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(atPath: testPath)
            return true
        } catch {
            return false
        }
    }
}
