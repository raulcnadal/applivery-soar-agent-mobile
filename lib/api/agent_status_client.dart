import 'dart:convert';
import 'dart:io';

import '../config/managed_config.dart';
import '../identity/mtls_identity.dart';

/// A single Compliance Policy scoped to this device's platform — mirrors
/// backend's `AgentStatusResponse.compliance.policies[]`
/// (deviceData.service.ts).
class AgentPolicySummary {
  const AgentPolicySummary(
      {required this.id, required this.name, required this.severity});

  final String id;
  final String name;
  final String severity;

  factory AgentPolicySummary.fromJson(Map<String, dynamic> json) =>
      AgentPolicySummary(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        severity: json['severity'] as String? ?? '',
      );
}

/// A single active policy violation on this device — mirrors backend's
/// `AgentStatusResponse.compliance.violations[]`.
class AgentPolicyViolation {
  const AgentPolicyViolation({
    required this.policyId,
    required this.policyName,
    required this.severity,
    required this.lastDetectedAt,
  });

  final String policyId;
  final String? policyName;
  final String? severity;
  final String? lastDetectedAt;

  factory AgentPolicyViolation.fromJson(Map<String, dynamic> json) =>
      AgentPolicyViolation(
        policyId: json['policyId'] as String? ?? '',
        policyName: json['policyName'] as String?,
        severity: json['severity'] as String?,
        lastDetectedAt: json['lastDetectedAt'] as String?,
      );
}

/// Mirrors backend's `AgentStatusResponse.compliance` — `available: false`
/// is a normal, expected state (no Automation Credential configured yet, or
/// this device hasn't been matched in the fleet), not an error; see
/// getAgentStatus's own doc comment in deviceData.service.ts.
class AgentComplianceStatus {
  const AgentComplianceStatus({
    required this.available,
    this.reason,
    this.compliant,
    this.riskScore,
    this.riskTier,
    this.policies = const [],
    this.violations = const [],
  });

  final bool available;
  final String? reason;
  final bool? compliant;
  final num? riskScore;
  final String? riskTier;
  final List<AgentPolicySummary> policies;
  final List<AgentPolicyViolation> violations;

  factory AgentComplianceStatus.fromJson(Map<String, dynamic> json) =>
      AgentComplianceStatus(
        available: json['available'] as bool? ?? false,
        reason: json['reason'] as String?,
        compliant: json['compliant'] as bool?,
        riskScore: json['riskScore'] as num?,
        riskTier: json['riskTier'] as String?,
        policies: (json['policies'] as List<dynamic>? ?? [])
            .map((p) => AgentPolicySummary.fromJson(p as Map<String, dynamic>))
            .toList(),
        violations: (json['violations'] as List<dynamic>? ?? [])
            .map(
                (v) => AgentPolicyViolation.fromJson(v as Map<String, dynamic>))
            .toList(),
      );
}

/// Full parsed response from GET /api/device-data/agent-status — mirrors
/// backend's `AgentStatusResponse` interface exactly (deviceData.service.ts).
class AgentStatusResult {
  const AgentStatusResult({
    required this.deviceMatched,
    this.deviceId,
    this.deviceDisplayName,
    required this.compliance,
  });

  final bool deviceMatched;
  final String? deviceId;
  final String? deviceDisplayName;
  final AgentComplianceStatus compliance;

  factory AgentStatusResult.fromJson(Map<String, dynamic> json) {
    final device = json['device'] as Map<String, dynamic>? ?? {};
    final compliance = json['compliance'] as Map<String, dynamic>? ?? {};
    return AgentStatusResult(
      deviceMatched: device['matched'] as bool? ?? false,
      deviceId: device['id'] as String?,
      deviceDisplayName: device['displayName'] as String?,
      compliance: AgentComplianceStatus.fromJson(compliance),
    );
  }
}

/// Thrown for anything that isn't "a valid AgentStatusResult" — a non-2xx
/// HTTP response, unparseable JSON, or the underlying mTLS request itself
/// failing (see [MtlsRequestException]).
class AgentStatusException implements Exception {
  AgentStatusException(this.message, {this.likelyMtlsNotEnforced = false});

  final String message;

  /// True when the failure looks like the workspace hasn't flipped
  /// `mtlsEnforcementEnabled` on yet — see verifyDeviceIdentity's own doc
  /// comment (backend deviceData.service.ts): until that flag is on, EVERY
  /// device-data call from this app fails the same way regardless of
  /// whether this device's own certificate is perfectly valid, because the
  /// server checks the legacy X-Device-Report-Secret header instead — a
  /// header mobile has no value for and never will (ARCHITECTURE.md §2.2:
  /// "no report_secret legacy path to carry forward"). Surfaced separately
  /// so the UI can show "ask your admin to enable mTLS enforcement for this
  /// workspace" instead of a generic network-error message.
  final bool likelyMtlsNotEnforced;

  @override
  String toString() => 'AgentStatusException: $message';
}

/// Calls GET /api/device-data/agent-status through the native
/// mTLS-authenticated HTTP client (MtlsIdentity.request) and parses the
/// result — the data source for the real compliance status screen
/// (lib/status/compliance_screen.dart).
class AgentStatusClient {
  AgentStatusClient._();
  static final AgentStatusClient instance = AgentStatusClient._();

  Future<AgentStatusResult> fetch(ManagedConfig config) async {
    if (config.deviceSerial == null || config.deviceSerial!.isEmpty) {
      throw AgentStatusException(
          'No device serial in Managed Configuration — cannot look up this device\'s status.');
    }

    final platform = Platform.isIOS
        ? 'ios'
        : Platform.isAndroid
            ? 'android'
            : '';
    final url = Uri.parse(config.baseUrl).resolve(
        '/api/device-data/agent-status?serialNumber=${Uri.encodeQueryComponent(config.deviceSerial!)}&platform=$platform');

    final MtlsHttpResponse response;
    try {
      response = await MtlsIdentity.instance.request(
        method: 'GET',
        url: url,
        headers: {'X-Workspace-Slug': config.workspaceSlug},
      );
    } on MtlsRequestException catch (error) {
      throw AgentStatusException('mTLS request failed: ${error.message}');
    }

    if (!response.isSuccess) {
      // A 401/403 here — with an otherwise-healthy enrolled identity — is
      // the exact symptom of the workspace not having mTLS enforcement
      // enabled yet (see AgentStatusException.likelyMtlsNotEnforced's doc
      // comment); 5xx or other 4xx are treated as ordinary failures.
      final likelyMtlsNotEnforced =
          response.statusCode == 401 || response.statusCode == 403;
      throw AgentStatusException(
        'Server rejected the request (HTTP ${response.statusCode}): ${_bodySnippet(response.body)}',
        likelyMtlsNotEnforced: likelyMtlsNotEnforced,
      );
    }

    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (error) {
      throw AgentStatusException('Could not parse status response: $error');
    }

    return AgentStatusResult.fromJson(decoded);
  }

  String _bodySnippet(String body) =>
      body.length > 300 ? '${body.substring(0, 300)}…' : body;
}
