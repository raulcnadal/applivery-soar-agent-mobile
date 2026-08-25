import 'dart:convert';
import 'dart:io';

import '../checks/device_security_telemetry.dart';
import '../config/managed_config.dart';
import '../identity/mtls_identity.dart';

/// Thrown for anything that isn't a successful report — same shape/intent
/// as CompliancePolicyException/AgentStatusException.
class DeviceReportException implements Exception {
  DeviceReportException(this.message);
  final String message;

  @override
  String toString() => 'DeviceReportException: $message';
}

/// The SOAR Mobile Agent's own call into the SAME device-facing self-report
/// endpoint the Windows/macOS agents already call every cycle —
/// POST /api/device-data/report (reportDeviceData, deviceData.service.ts).
/// That endpoint is, and always was, fully platform-agnostic (plain
/// `platform: z.string()` in deviceReportPayloadSchema, no windows/macos
/// branching anywhere in reportDeviceData itself) — the mobile app simply
/// never called it before now (see the mobile repo's ARCHITECTURE.md §3,
/// "an endpoint mobile never calls"). This client is what starts that:
/// collects whatever DeviceSecurityTelemetryChannel.collect() has for this
/// platform (currently just iOS's `devicePasscodeSet`; Android's own
/// signals land in that same map in later phases with zero change needed
/// here) and pushes it as `attributes`, exactly the shape
/// WINDOWS_ATTR_ALIASES/MACOS_ATTR_ALIASES-adjacent self-reported-attribute
/// conditions already expect on the Compliance Policy side.
///
/// No alias table exists for ios/android server-side
/// (normalizePushedAttributes, deviceData.schemas.ts) — whatever key name
/// is sent here IS the name a policy's selfReportedAttribute condition must
/// reference, so native plugin key names and Compliance Policy Template
/// condition names (complianceFields.ts) must be kept in lockstep by hand;
/// there's no server-side translation layer to fall back on for mobile the
/// way there is for Windows/macOS.
class DeviceReportClient {
  DeviceReportClient._();
  static final DeviceReportClient instance = DeviceReportClient._();

  Future<void> reportSecurityTelemetry(ManagedConfig config) async {
    if (config.deviceSerial == null || config.deviceSerial!.isEmpty) {
      throw DeviceReportException(
          'No device serial in Managed Configuration — cannot report telemetry.');
    }

    final attributes = await DeviceSecurityTelemetryChannel.instance.collect();
    // Nothing to report yet (e.g. Android before Phase 2/3 land their own
    // checks) — skip the call entirely rather than sending an empty
    // attributes payload that would just bump reportCount for no reason.
    if (attributes.isEmpty) return;

    final platform = Platform.isIOS
        ? 'ios'
        : Platform.isAndroid
            ? 'android'
            : '';

    final url = Uri.parse(config.baseUrl).resolve('/api/device-data/report');
    final payload = jsonEncode({
      'platform': platform,
      'serialNumber': config.deviceSerial,
      'attributes': attributes,
      // agentVersion is optional server-side (deviceReportPayloadSchema) —
      // pubspec.yaml has no package_info_plus-style dependency to read the
      // app's own build version yet, so this is simply omitted rather than
      // pulling in a new package for one nullable field. Can be added later
      // without any other change to this client.
      'reportedAt': DateTime.now().toUtc().toIso8601String(),
    });

    final MtlsHttpResponse response;
    try {
      response = await MtlsIdentity.instance.request(
        method: 'POST',
        url: url,
        headers: {
          'X-Workspace-Slug': config.workspaceSlug,
          'Content-Type': 'application/json',
        },
        body: payload,
      );
    } on MtlsRequestException catch (error) {
      throw DeviceReportException('mTLS request failed: ${error.message}');
    }

    if (!response.isSuccess) {
      throw DeviceReportException(
        'Server rejected the report (HTTP ${response.statusCode}): ${_bodySnippet(response.body)}',
      );
    }
  }

  String _bodySnippet(String body) =>
      body.length > 300 ? '${body.substring(0, 300)}…' : body;
}
