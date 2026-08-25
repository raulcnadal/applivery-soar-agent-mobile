import 'package:flutter/services.dart';

/// Bridges the native device-security-telemetry channels
/// (ios/Runner/DeviceSecurityTelemetryPlugin.swift,
/// android/.../DeviceSecurityTelemetryPlugin.kt) — one shared channel name
/// and method across both platforms, same "no branching needed here"
/// pattern as IntegrityChannel (checks/integrity.dart). Distinct from that
/// channel: this one collects security-POSTURE attributes meant to be
/// self-reported to SOAR as compliance telemetry (see
/// api/device_report_client.dart), not compromise-detection signals shown
/// locally in the Diagnostics drawer.
///
/// The returned map's keys are already the exact attribute names the
/// compliance engine expects (e.g. `devicePasscodeSet`) — see
/// backend's deviceData.schemas.ts normalizePushedAttributes doc comment:
/// iOS/Android have no alias table, so whatever key name is sent here is
/// exactly the name a Compliance Policy's selfReportedAttribute condition
/// must reference.
class DeviceSecurityTelemetryChannel {
  DeviceSecurityTelemetryChannel._();
  static final DeviceSecurityTelemetryChannel instance =
      DeviceSecurityTelemetryChannel._();

  static const MethodChannel _channel =
      MethodChannel('es.applivery.soar/device_telemetry');

  /// Best-effort — on any platform-channel failure (missing plugin, native
  /// exception), returns an empty map rather than throwing, so a telemetry
  /// collection hiccup never blocks the report cycle's other attributes or
  /// crashes the report call itself.
  Future<Map<String, dynamic>> collect() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('collect');
      if (raw == null) return const {};
      return raw.map((key, value) => MapEntry(key.toString(), value));
    } catch (_) {
      return const {};
    }
  }
}
