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
///
/// Mobile telemetry roadmap Phase 4: expanded path lists and an additional
/// dylib-injection check, from the reference article ("Jail Break Detection
/// IOS Swift 2025") covering traditional AND modern jailbreaks (rootless
/// `/var/jb`, palera1n, TrollStore, checkra1n) — the original Phase-1-era
/// list only covered traditional (pre-rootless) jailbreaks.
final class JailbreakDetectorPlugin: NSObject, FlutterPlugin {
    private static let channelName = "es.applivery.soar/root_detector"

    private static let suspiciousAppPaths = [
        // Traditional jailbreaks
        "/Applications/Cydia.app",
        "/Applications/blackra1n.app",
        "/Applications/FakeCarrier.app",
        "/Applications/Icy.app",
        "/Applications/IntelliScreen.app",
        "/Applications/MxTube.app",
        "/Applications/RockApp.app",
        "/Applications/SBSettings.app",
        "/Applications/WinterBoard.app",
        "/Applications/Sileo.app",
        "/Applications/Zebra.app",
        "/Applications/Installer.app",
        // Modern jailbreaks
        "/Applications/Palera1n.app",
        "/Applications/TrollStore.app",
        "/var/containers/Bundle/Application/TrollStore.app",
        "/Applications/checkra1n.app",
        // Rootless jailbreak paths
        "/var/jb/Applications/Cydia.app",
        "/var/jb/Applications/Sileo.app",
        "/var/jb/Applications/Zebra.app",
    ]

    private static let suspiciousSystemPaths = [
        // Traditional paths
        "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/Library/MobileSubstrate/DynamicLibraries/LiveClock.plist",
        "/Library/MobileSubstrate/DynamicLibraries/Veency.plist",
        "/usr/sbin/sshd",
        "/etc/apt",
        "/bin/bash",
        "/private/var/lib/apt",
        "/private/var/lib/cydia",
        "/private/var/mobile/Library/SBSettings/Themes",
        "/private/var/stash",
        "/private/var/tmp/cydia.log",
        "/System/Library/LaunchDaemons/com.ikey.bbot.plist",
        "/System/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist",
        // Modern jailbreak paths
        "/var/jb", // Rootless jailbreak root (Dopamine and similar, post-iOS 15)
        "/var/binpack", // Checkm8 jailbreak
        "/var/containers/Bundle/tweaksupport",
        "/var/mobile/Library/palera1n",
        "/var/lib/undecimus",
        "/var/jb/basebin",
        "/var/jb/.installed_palera1n",
        "/var/containers/Bundle/Application/trollstorehelper",
        "/var/containers/Bundle/trollstore",
    ]

    // Each of these MUST also be listed under LSApplicationQueriesSchemes in
    // Info.plist — canOpenURL(_:) always returns false for an
    // undeclared scheme regardless of whether the handling app is actually
    // installed (iOS 9+ privacy restriction), so omitting that entry here
    // would silently make this check a permanent no-op.
    private static let suspiciousSchemes = ["cydia://", "sileo://", "zbra://", "filza://"]

    // Substrate/hooking dylibs — loadable via dlopen only when a jailbreak
    // tweak injection framework is actually active in this process. The
    // reference article calls this "an alternative to fork()": fork() itself
    // is sandboxed/unavailable in a normal iOS app process, so this dylib
    // probe is the practical equivalent for detecting a tweak-injection
    // environment.
    private static let suspiciousDylibs = [
        "SubstrateLoader.dylib",
        "libhooker.dylib",
        "SubstrateBootstrap.dylib",
        "libsubstitute.dylib",
        "libellekit.dylib",
    ]

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

        let foundAppPaths = suspiciousAppPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if !foundAppPaths.isEmpty {
            signals.append("suspicious_app_present:\(foundAppPaths.joined(separator: ","))")
        }

        let foundSystemPaths = suspiciousSystemPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if !foundSystemPaths.isEmpty {
            signals.append("suspicious_system_path_present:\(foundSystemPaths.joined(separator: ","))")
        }

        if canOpenSuspiciousScheme() {
            signals.append("suspicious_url_scheme_openable")
        }

        if canWriteOutsideSandbox() {
            signals.append("sandbox_escape_write_succeeded")
        }

        if hasSuspiciousDylibLoaded() {
            signals.append("suspicious_dylib_loaded")
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

    /// `dlopen` on a substrate/hooking dylib name only succeeds when a
    /// tweak-injection framework has actually loaded it into this process —
    /// a stock, unmodified app can never resolve these. `RTLD_NOW` (not
    /// `RTLD_LAZY`) forces immediate symbol resolution so a false "success"
    /// from a merely-similarly-named-but-broken library can't slip through.
    private static func hasSuspiciousDylibLoaded() -> Bool {
        for library in suspiciousDylibs {
            if dlopen(library, RTLD_NOW) != nil {
                return true
            }
        }
        return false
    }
}
