import 'package:flutter/services.dart';

/// Result of a jailbreak/root heuristic check. See
/// android/app/src/main/kotlin/com/applivery/soar/mobile/RootDetectorPlugin.kt
/// and ios/Runner/JailbreakDetector.swift for what actually runs.
///
/// Deliberately a list of matched signals, not just a bool: useful both for
/// the compliance status screen (show *why*, not just a red/green dot) and
/// for feeding a selfReported.customCheckResults-shaped payload to the SOAR
/// backend later — same "structured result, not a bare boolean" shape the
/// desktop agents' Custom Device Checks already use
/// (backend customChecks.service.ts).
class IntegrityCheckResult {
  const IntegrityCheckResult({required this.isCompromised, required this.signals});

  final bool isCompromised;
  final List<String> signals;

  static const IntegrityCheckResult clean = IntegrityCheckResult(isCompromised: false, signals: []);

  factory IntegrityCheckResult.fromMap(Map<Object?, Object?> map) {
    final rawSignals = map['signals'];
    return IntegrityCheckResult(
      isCompromised: map['isCompromised'] as bool? ?? false,
      signals: rawSignals is List ? rawSignals.map((e) => e.toString()).toList() : const [],
    );
  }

  @override
  String toString() => 'IntegrityCheckResult(isCompromised: $isCompromised, signals: $signals)';
}

/// Bridges the native root/jailbreak detection channels — a single shared
/// channel name and method across both platforms (RootDetectorPlugin.kt /
/// JailbreakDetector.swift), so this wrapper needs no platform branching.
class IntegrityChannel {
  IntegrityChannel._();
  static final IntegrityChannel instance = IntegrityChannel._();

  static const MethodChannel _channel = MethodChannel('es.applivery.soar/root_detector');

  /// Best-effort, not tamper-proof — see the native implementations' own
  /// doc comments. Call on demand (e.g. once per report cycle, or when the
  /// compliance status screen opens); there's no live-updates stream for
  /// this one, unlike ManagedConfigChannel.watch() — root/jailbreak status
  /// doesn't change while the app is running under any normal circumstance,
  /// so a push channel would only add complexity for no real benefit.
  Future<IntegrityCheckResult> check() async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>('checkIntegrity');
    if (raw == null) return IntegrityCheckResult.clean;
    return IntegrityCheckResult.fromMap(raw);
  }
}
