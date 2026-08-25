import Flutter
import Foundation
import MachO
import UIKit

/// Heuristic jailbreak detection — the SOAR Mobile Agent's in-house RASP
/// (Runtime Application Self-Protection) foundation. See
/// android/app/src/main/kotlin/.../RootDetectorPlugin.kt for the Android
/// equivalent and the same "signals bucketed into 3 categories, not a
/// single boolean" contract: useful both for the compliance status screen
/// (show *why*, not just a red/green dot) and for feeding
/// device_report_client.dart's report payload.
///
/// Best-effort, not tamper-proof — same caveat class as the Windows/macOS
/// agents' mutual-watchdog anti-tampering (their own ARCHITECTURE.md §2): a
/// deterrent against a casual/default jailbreak, not a guarantee against a
/// determined attacker. A jailbreak using a hiding tweak (Shadow, Flex, or
/// rootless jailbreaks' own built-in hiding) can defeat some or all of these
/// checks; this raises the bar, it isn't a security boundary on its own.
///
/// Mobile telemetry roadmap Phase 4 expanded path lists and added the
/// dylib-injection check, covering traditional AND modern jailbreaks
/// (rootless `/var/jb`, palera1n, TrollStore, checkra1n). Phase 5 (this
/// pass) is the in-house RASP roadmap: rather than paying for freeRASP's
/// highest tier (needed to control where its telemetry is reported — a
/// non-starter for a self-hosted SOAR that must keep this data in its own
/// pipeline), this class absorbs the equivalent detection techniques
/// directly, and — new this phase — buckets every signal into three named
/// categories (`isRootedOrJailbroken`/`isDebuggerAttached`/
/// `isHookingFrameworkDetected`) instead of one merged `isCompromised`
/// boolean, so each can become its own Compliance Policy condition
/// (complianceFields.ts's SELF_REPORTED_ATTRIBUTE_CATALOG) rather than
/// conflating "this device is jailbroken" with "someone has a debugger
/// attached to it right now" — genuinely different risk profiles.
///
/// Two new Phase 5 techniques, both from Apple's own documented QA1361
/// technique and dyld's public introspection API:
/// - `isDebuggerAttached()`: `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID,
///   getpid())` reads this process's own `kinfo_proc`, whose `p_flag` bit
///   `P_TRACED` is the kernel's own record of whether a debugger (Xcode's
///   LLDB, or a jailbreak tool like a re-signed debugserver) is currently
///   attached — this is Apple's own documented anti-debugging technique,
///   not a heuristic.
/// - `hasInjectedLibraryLoaded()`: `_dyld_image_count()`/
///   `_dyld_get_image_name()` enumerate EVERY dynamic library actually
///   loaded into this process by name — catches an injected Frida/
///   Substrate/Cycript gadget regardless of what path or name it was
///   loaded under, a broader net than the fixed dylib-name `dlopen()` probe
///   below (which only catches a KNOWN library name).
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

    // Substrings matched (case-insensitively) against every currently-loaded
    // dyld image's full path — a broader net than suspiciousDylibs' exact
    // dlopen() probe above, since it catches an injected library regardless
    // of the exact filename or install path used.
    private static let dyldImageHookingMarkers = ["frida", "gadget", "substrate", "cycript", "libhooker"]

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
        //
        // The debugger-attached check is deliberately excluded from this
        // skip: Xcode routinely attaches LLDB to Simulator builds during
        // normal development, so reporting isDebuggerAttached from the
        // Simulator would be a constant, meaningless false positive for
        // every dev-loop run, not a real signal.
        return [
            "isCompromised": false,
            "signals": ["simulator_checks_skipped"],
            "isRootedOrJailbroken": false,
            "isDebuggerAttached": false,
            "isHookingFrameworkDetected": false,
        ]
        #else
        var jailbrokenSignals: [String] = []
        var debuggerSignals: [String] = []
        var hookingSignals: [String] = []

        // -- Jailbroken signals --
        let foundAppPaths = suspiciousAppPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if !foundAppPaths.isEmpty {
            jailbrokenSignals.append("suspicious_app_present:\(foundAppPaths.joined(separator: ","))")
        }

        let foundSystemPaths = suspiciousSystemPaths.filter { FileManager.default.fileExists(atPath: $0) }
        if !foundSystemPaths.isEmpty {
            jailbrokenSignals.append("suspicious_system_path_present:\(foundSystemPaths.joined(separator: ","))")
        }

        if canOpenSuspiciousScheme() {
            jailbrokenSignals.append("suspicious_url_scheme_openable")
        }

        if canWriteOutsideSandbox() {
            jailbrokenSignals.append("sandbox_escape_write_succeeded")
        }

        // -- Debugger-attached signal (an active session against THIS process right now) --
        if isDebuggerAttached() {
            debuggerSignals.append("ptrace_p_traced_flag_set")
        }

        // -- Hooking/instrumentation-framework signals --
        if hasSuspiciousDylibLoaded() {
            hookingSignals.append("suspicious_dylib_loaded")
        }
        let injectedMarkers = injectedLibraryMarkers()
        if !injectedMarkers.isEmpty {
            hookingSignals.append("dyld_image_markers:\(injectedMarkers.joined(separator: ","))")
        }

        let allSignals = jailbrokenSignals + debuggerSignals + hookingSignals
        return [
            "isCompromised": !allSignals.isEmpty,
            "signals": allSignals,
            "isRootedOrJailbroken": !jailbrokenSignals.isEmpty,
            "isDebuggerAttached": !debuggerSignals.isEmpty,
            "isHookingFrameworkDetected": !hookingSignals.isEmpty,
        ]
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

    /// Apple's own documented anti-debugging technique (Technical Q&A
    /// QA1361): `sysctl` with `{CTL_KERN, KERN_PROC, KERN_PROC_PID,
    /// getpid()}` fills in a `kinfo_proc` describing this process as the
    /// kernel sees it right now, including `kp_proc.p_flag`. The `P_TRACED`
    /// bit is set by the kernel for the lifetime of a ptrace-based debug
    /// session (Xcode/LLDB on a real device, or a re-signed debugserver
    /// under a jailbreak) — reading it is the standard, Apple-sanctioned way
    /// to detect this without any private API.
    private static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
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

    /// `_dyld_image_count()`/`_dyld_get_image_name()` enumerate EVERY dynamic
    /// library dyld has actually loaded into this process, by its full
    /// on-disk path — unlike `hasSuspiciousDylibLoaded()`'s fixed-name
    /// `dlopen()` probe, this catches an injected library regardless of the
    /// exact filename or directory it was placed under, since a process
    /// can't hide an image from its own loaded-image list once it's mapped.
    private static func injectedLibraryMarkers() -> [String] {
        var found = Set<String>()
        let count = _dyld_image_count()
        for i in 0..<count {
            guard let namePointer = _dyld_get_image_name(i) else { continue }
            let path = String(cString: namePointer).lowercased()
            for marker in dyldImageHookingMarkers where path.contains(marker) {
                found.insert(marker)
            }
        }
        return Array(found)
    }
}
