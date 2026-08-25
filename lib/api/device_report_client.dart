import 'dart:convert';
import 'dart:io';

import '../checks/device_security_telemetry.dart';
import '../checks/integrity.dart';
import '../config/managed_config.dart';
import '../identity/mtls_identity.dart';
import 'play_integrity_client.dart';

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

    // Mobile telemetry roadmap Phase 4 — root/jailbreak foundation signals
    // (RootDetectorPlugin.kt / JailbreakDetector.swift, shared
    // `es.applivery.soar/root_detector` channel already used locally by the
    // compliance status screen's Diagnostics drawer) now ALSO ride along on
    // this same report. Phase 5 (in-house RASP) split what used to be a
    // single `deviceRootedOrJailbroken` boolean into three independently
    // reportable attributes — matching the native plugins' own restructured
    // {isRootedOrJailbroken, isDebuggerAttached, isHookingFrameworkDetected}
    // return shape — so a Compliance Policy condition can target "is this
    // device rooted" separately from "does it have a debugger/hooking
    // framework attached right now". Best-effort throughout: any channel
    // failure here must never block the rest of the report, so a
    // clean/unknown result is assumed on error rather than throwing.
    bool deviceRootedOrJailbroken = false;
    bool deviceDebuggerAttached = false;
    bool deviceHookingFrameworkDetected = false;
    try {
      final integrity = await IntegrityChannel.instance.check();
      deviceRootedOrJailbroken = integrity.isRootedOrJailbroken;
      deviceDebuggerAttached = integrity.isDebuggerAttached;
      deviceHookingFrameworkDetected = integrity.isHookingFrameworkDetected;
    } catch (_) {
      // Leave everything false — an unreadable channel isn't itself evidence
      // of compromise, and every other attribute in this report is still
      // worth sending.
    }
    attributes['deviceRootedOrJailbroken'] = deviceRootedOrJailbroken;
    attributes['deviceDebuggerAttached'] = deviceDebuggerAttached;
    attributes['deviceHookingFrameworkDetected'] =
        deviceHookingFrameworkDetected;

    final platform = Platform.isIOS
        ? 'ios'
        : Platform.isAndroid
            ? 'android'
            : '';

    // Android-only, best-effort (see PlayIntegrityClient's own doc comment):
    // a nonce fetch, a native Classic API call, and a throttle window all
    // have to line up for this to be non-null on any given cycle — a null
    // here simply means the report goes out without a fresh integrity
    // verdict this time, not that the report itself fails. Phase 4: also
    // skipped outright on a device DeviceSecurityTelemetryChannel already
    // identified as AOSP (Play Integrity is Play-Services-only) — see
    // PlayIntegrityClient.fetchToken's own doc comment.
    final playIntegrityToken = await PlayIntegrityClient.instance.fetchToken(
      config,
      platformFamily: attributes['androidPlatformFamily'] as String?,
    );

    final url = Uri.parse(config.baseUrl).resolve('/api/device-data/report');
    final payload = jsonEncode({
      'platform': platform,
      'serialNumber': config.deviceSerial,
      'attributes': attributes,
      if (playIntegrityToken != null) 'playIntegrityToken': playIntegrityToken,
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
