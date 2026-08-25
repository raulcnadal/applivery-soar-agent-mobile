import 'package:flutter/services.dart';

/// Result of a jailbreak/root/RASP heuristic check. See
/// android/app/src/main/kotlin/com/applivery/soar/mobile/RootDetectorPlugin.kt
/// and ios/Runner/JailbreakDetector.swift for what actually runs.
///
/// Deliberately a list of matched signals, not just a bool: useful both for
/// the compliance status screen (show *why*, not just a red/green dot) and
/// for feeding a selfReported.customCheckResults-shaped payload to the SOAR
/// backend later — same "structured result, not a bare boolean" shape the
/// desktop agents' Custom Device Checks already use
/// (backend customChecks.service.ts).
///
/// Mobile telemetry roadmap Phase 5 (in-house RASP) split the original
/// single `isCompromised` boolean into three independently-reportable
/// categories — `isRootedOrJailbroken`, `isDebuggerAttached`,
/// `isHookingFrameworkDetected` — matching the native plugins' own
/// restructured return shape, so each becomes its own Compliance Policy
/// condition instead of one conflated signal. `isCompromised` is kept as
/// the OR of all three for any caller that only cares about the coarse
/// verdict (e.g. an at-a-glance status badge).
class IntegrityCheckResult {
  const IntegrityCheckResult({
    required this.isCompromised,
    required this.signals,
    required this.isRootedOrJailbroken,
    required this.isDebuggerAttached,
    required this.isHookingFrameworkDetected,
  });

  final bool isCompromised;
  final List<String> signals;
  final bool isRootedOrJailbroken;
  final bool isDebuggerAttached;
  final bool isHookingFrameworkDetected;

  static const IntegrityCheckResult clean = IntegrityCheckResult(
    isCompromised: false,
    signals: [],
    isRootedOrJailbroken: false,
    isDebuggerAttached: false,
    isHookingFrameworkDetected: false,
  );

  factory IntegrityCheckResult.fromMap(Map<Object?, Object?> map) {
    final rawSignals = map['signals'];
    return IntegrityCheckResult(
      isCompromised: map['isCompromised'] as bool? ?? false,
      signals: rawSignals is List
          ? rawSignals.map((e) => e.toString()).toList()
          : const [],
      // Fall back to false (not to isCompromised) for a stale native build
      // that hasn't shipped these keys yet — this is a genuinely new,
      // narrower signal, not a renamed one, so it shouldn't silently
      // inherit the coarse verdict.
      isRootedOrJailbroken: map['isRootedOrJailbroken'] as bool? ?? false,
      isDebuggerAttached: map['isDebuggerAttached'] as bool? ?? false,
      isHookingFrameworkDetected:
          map['isHookingFrameworkDetected'] as bool? ?? false,
    );
  }

  @override
  String toString() =>
      'IntegrityCheckResult(isCompromised: $isCompromised, signals: $signals, '
      'isRootedOrJailbroken: $isRootedOrJailbroken, isDebuggerAttached: $isDebuggerAttached, '
      'isHookingFrameworkDetected: $isHookingFrameworkDetected)';
}

/// Bridges the native root/jailbreak detection channels — a single shared
/// channel name and method across both platforms (RootDetectorPlugin.kt /
/// JailbreakDetector.swift), so this wrapper needs no platform branching.
class IntegrityChannel {
  IntegrityChannel._();
  static final IntegrityChannel instance = IntegrityChannel._();

  static const MethodChannel _channel =
      MethodChannel('es.applivery.soar/root_detector');

  /// Best-effort, not tamper-proof — see the native implementations' own
  /// doc comments. Call on demand (e.g. once per report cycle, or when the
  /// compliance status screen opens); there's no live-updates stream for
  /// this one, unlike ManagedConfigChannel.watch() — root/jailbreak status
  /// doesn't change while the app is running under any normal circumstance,
  /// so a push channel would only add complexity for no real benefit.
  Future<IntegrityCheckResult> check() async {
    final raw =
        await _channel.invokeMethod<Map<Object?, Object?>>('checkIntegrity');
    if (raw == null) return IntegrityCheckResult.clean;
    return IntegrityCheckResult.fromMap(raw);
  }
}
