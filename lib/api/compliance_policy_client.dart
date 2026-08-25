import 'dart:convert';

import '../config/managed_config.dart';
import '../identity/mtls_identity.dart';

/// One condition inside a Compliance Policy, with whether it currently
/// matches THIS device — mirrors backend's evaluatePolicyForDevice
/// (devices.service.ts) `conditions[]` shape, returned via
/// GET /api/device-data/compliance-policy (deviceData.service.ts's
/// getAgentCompliancePolicyStatus — the mTLS-gated equivalent of the
/// dashboard's own per-condition lookup, added for this screen).
class PolicyCondition {
  const PolicyCondition({
    required this.field,
    required this.operator,
    required this.value,
    required this.met,
  });

  final String field;
  final String operator;
  final dynamic value;

  /// True = this condition currently matches on this device — i.e. it's
  /// "red" (contributing to a violation), matching the web dashboard's
  /// DeviceCompliancePolicyStatusModal.vue convention exactly (met == red).
  final bool met;

  factory PolicyCondition.fromJson(Map<String, dynamic> json) =>
      PolicyCondition(
        field: json['field'] as String? ?? '',
        operator: json['operator'] as String? ?? '',
        value: json['value'],
        met: json['met'] as bool? ?? false,
      );
}

/// Full per-condition detail for one policy on one device — mirrors
/// backend's evaluatePolicyForDevice return shape exactly.
class CompliancePolicyDetail {
  const CompliancePolicyDetail({
    required this.policyId,
    required this.policyName,
    required this.conditionLogic,
    required this.lastEvaluatedAt,
    required this.violated,
    required this.conditions,
  });

  final String policyId;
  final String policyName;

  /// "any" or "all" — see [conditionLogicIsAll].
  final String conditionLogic;
  final String? lastEvaluatedAt;
  final bool violated;
  final List<PolicyCondition> conditions;

  bool get conditionLogicIsAll => conditionLogic == 'all';

  factory CompliancePolicyDetail.fromJson(Map<String, dynamic> json) =>
      CompliancePolicyDetail(
        policyId: json['policyId'] as String? ?? '',
        policyName: json['policyName'] as String? ?? '',
        conditionLogic: json['conditionLogic'] as String? ?? 'any',
        lastEvaluatedAt: json['lastEvaluatedAt'] as String?,
        violated: json['violated'] as bool? ?? false,
        conditions: (json['conditions'] as List<dynamic>? ?? [])
            .map((c) => PolicyCondition.fromJson(c as Map<String, dynamic>))
            .toList(),
      );
}

/// Thrown for anything that isn't a valid [CompliancePolicyDetail] — same
/// shape/intent as [AgentStatusException] in agent_status_client.dart.
class CompliancePolicyException implements Exception {
  CompliancePolicyException(this.message);
  final String message;

  @override
  String toString() => 'CompliancePolicyException: $message';
}

/// Calls GET /api/device-data/compliance-policy through the native
/// mTLS-authenticated HTTP client — the data source for
/// lib/status/policy_detail_screen.dart. Same auth/parsing pattern as
/// AgentStatusClient (agent_status_client.dart); kept as a separate client
/// rather than folded into that one since this is a distinct, on-demand,
/// per-policy call (only made when the user taps into a specific policy),
/// not part of the main status poll.
class CompliancePolicyClient {
  CompliancePolicyClient._();
  static final CompliancePolicyClient instance = CompliancePolicyClient._();

  Future<CompliancePolicyDetail> fetch(
      ManagedConfig config, String policyId) async {
    if (config.deviceSerial == null || config.deviceSerial!.isEmpty) {
      throw CompliancePolicyException(
          'No device serial in Managed Configuration — cannot look up this policy\'s status.');
    }

    final url = Uri.parse(config.baseUrl).resolve(
      '/api/device-data/compliance-policy'
      '?serialNumber=${Uri.encodeQueryComponent(config.deviceSerial!)}'
      '&policyId=${Uri.encodeQueryComponent(policyId)}',
    );

    final MtlsHttpResponse response;
    try {
      response = await MtlsIdentity.instance.request(
        method: 'GET',
        url: url,
        headers: {'X-Workspace-Slug': config.workspaceSlug},
      );
    } on MtlsRequestException catch (error) {
      throw CompliancePolicyException('mTLS request failed: ${error.message}');
    }

    if (!response.isSuccess) {
      throw CompliancePolicyException(
        'Server rejected the request (HTTP ${response.statusCode}): ${_bodySnippet(response.body)}',
      );
    }

    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (error) {
      throw CompliancePolicyException(
          'Could not parse policy status response: $error');
    }

    return CompliancePolicyDetail.fromJson(decoded);
  }

  String _bodySnippet(String body) =>
      body.length > 300 ? '${body.substring(0, 300)}…' : body;
}
