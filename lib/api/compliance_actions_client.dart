import 'dart:convert';

import '../config/managed_config.dart';
import '../identity/mtls_identity.dart';

/// Result of a successful "Force evaluate compliance" call — mirrors
/// backend's `EvaluationSummary` (compliance.service.ts), trimmed to the
/// fields worth surfacing on a small mobile status message (evaluatedPolicies/
/// devicesChecked/violationsFound); autoFired/queuedForReview/recovered/
/// autoRunSafetyBlocked are workflow-automation bookkeeping this app has no
/// UI for and doesn't need.
class ComplianceEvaluationSummary {
  const ComplianceEvaluationSummary({
    required this.evaluatedPolicies,
    required this.devicesChecked,
    required this.violationsFound,
  });

  final int evaluatedPolicies;
  final int devicesChecked;
  final int violationsFound;

  factory ComplianceEvaluationSummary.fromJson(Map<String, dynamic> json) =>
      ComplianceEvaluationSummary(
        evaluatedPolicies: (json['evaluatedPolicies'] as num?)?.toInt() ?? 0,
        devicesChecked: (json['devicesChecked'] as num?)?.toInt() ?? 0,
        violationsFound: (json['violationsFound'] as num?)?.toInt() ?? 0,
      );

  String get summaryLine =>
      'Evaluated $evaluatedPolicies ${evaluatedPolicies == 1 ? 'policy' : 'policies'} across $devicesChecked ${devicesChecked == 1 ? 'device' : 'devices'} — $violationsFound ${violationsFound == 1 ? 'violation' : 'violations'} found.';
}

/// Thrown for anything that isn't a successful evaluation — a non-2xx HTTP
/// response, unparseable JSON, or the underlying mTLS request itself
/// failing.
class ComplianceActionException implements Exception {
  ComplianceActionException(this.message, {this.isCooldown = false});

  final String message;

  /// True for a 429 — forceEvaluateNow's own 60s per-workspace cooldown
  /// (compliance.service.ts), not a real error; the UI can phrase this more
  /// gently ("already ran recently") than a generic failure.
  final bool isCooldown;

  @override
  String toString() => 'ComplianceActionException: $message';
}

/// "Force evaluate compliance" — the mobile equivalent of the Windows/macOS
/// SOAR Agent tray/menu action of the same name. Calls
/// POST /api/device-data/evaluate-now (deviceData.controller.ts), which reuses
/// the exact same device-caller mTLS auth as AgentStatusClient.fetch and
/// DeviceReportClient's report call.
///
/// Device-scoped, not fleet-wide: passes this device's own
/// `config.deviceSerial` as `?serialNumber=`, which the backend
/// (`runComplianceEvaluation`'s `onlyDeviceSerial`) uses to make sure this
/// pass can only ever create/clear a violation, fire a workflow, send an
/// alert, or apply a tag for THIS device — never as a side effect for any
/// other device in the workspace. It does NOT reduce how much data the
/// backend pulls from Applivery to do this (there's no single-device fetch
/// path against Applivery's own device-list API), so this isn't meaningfully
/// "faster" than the fleet-wide pass the desktop agents' own button
/// triggers — it's about blast radius and a per-device cooldown that no
/// longer collides with every other device in the workspace also pressing
/// this button, not about API cost.
class ComplianceActionsClient {
  ComplianceActionsClient._();
  static final ComplianceActionsClient instance = ComplianceActionsClient._();

  Future<ComplianceEvaluationSummary> forceEvaluate(
      ManagedConfig config) async {
    final baseUrl =
        Uri.parse(config.baseUrl).resolve('/api/device-data/evaluate-now');
    final url = (config.deviceSerial != null && config.deviceSerial!.isNotEmpty)
        ? baseUrl.replace(
            queryParameters: {'serialNumber': config.deviceSerial},
          )
        : baseUrl;

    final MtlsHttpResponse response;
    try {
      response = await MtlsIdentity.instance.request(
        method: 'POST',
        url: url,
        headers: {'X-Workspace-Slug': config.workspaceSlug},
      );
    } on MtlsRequestException catch (error) {
      throw ComplianceActionException('mTLS request failed: ${error.message}');
    }

    if (!response.isSuccess) {
      throw ComplianceActionException(
        'Server rejected the request (HTTP ${response.statusCode}): ${_detailOrSnippet(response.body)}',
        isCooldown: response.statusCode == 429,
      );
    }

    try {
      return ComplianceEvaluationSummary.fromJson(
          jsonDecode(response.body) as Map<String, dynamic>);
    } catch (error) {
      throw ComplianceActionException(
          'Could not parse evaluation response: $error');
    }
  }

  /// Backend error responses are `{ detail: "..." }` (HttpError,
  /// httpError.ts) — prefer that human-readable message when present, same
  /// convention the frontend's own `err?.response?.data?.detail` reads
  /// everywhere else in this app's ecosystem.
  String _detailOrSnippet(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] is String) {
        return decoded['detail'] as String;
      }
    } catch (_) {
      // Not JSON, or not the expected shape — fall through to the raw
      // snippet below.
    }
    return body.length > 300 ? '${body.substring(0, 300)}…' : body;
  }
}
