import 'package:flutter/material.dart';

import '../api/compliance_policy_client.dart';
import '../config/managed_config.dart';
import '../theme/design_tokens.dart';

/// Per-condition detail for one Compliance Policy on this device — opened by
/// tapping a policy row in ComplianceScreen's _CompliancePoliciesCard.
/// Mirrors the web dashboard's Device Modal policy view
/// (DeviceCompliancePolicyStatusModal.vue): a Violating/Compliant pill, an
/// "ANY/ALL conditions" note, then each condition with a red/green dot for
/// whether it currently matches, and the same explanatory legend text at the
/// bottom.
class PolicyDetailScreen extends StatefulWidget {
  const PolicyDetailScreen({
    super.key,
    required this.config,
    required this.policyId,
    required this.policyName,
  });

  final ManagedConfig config;
  final String policyId;

  /// Shown as the AppBar title immediately, before the real fetch (which
  /// also returns its own policyName) completes — avoids a blank title
  /// flash on first paint.
  final String policyName;

  @override
  State<PolicyDetailScreen> createState() => _PolicyDetailScreenState();
}

class _PolicyDetailScreenState extends State<PolicyDetailScreen> {
  bool _loading = true;
  CompliancePolicyDetail? _detail;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await CompliancePolicyClient.instance
          .fetch(widget.config, widget.policyId);
      if (!mounted) return;
      setState(() => _detail = detail);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_detail?.policyName ?? widget.policyName,
            overflow: TextOverflow.ellipsis),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _ErrorState(error: _error!, onRetry: _load)
                : _detail == null
                    ? const SizedBox.shrink()
                    : _PolicyDetailBody(detail: _detail!),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 40),
        Text(
          error is CompliancePolicyException
              ? (error as CompliancePolicyException).message
              : '$error',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.danger),
        ),
        const SizedBox(height: 16),
        Center(
          child: FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ),
      ],
    );
  }
}

class _PolicyDetailBody extends StatelessWidget {
  const _PolicyDetailBody({required this.detail});
  final CompliancePolicyDetail detail;

  @override
  Widget build(BuildContext context) {
    final lastEvaluatedLabel = detail.lastEvaluatedAt == null
        ? 'Not evaluated yet'
        : _formatTimestamp(detail.lastEvaluatedAt!);
    final logicLabel = detail.conditionLogicIsAll ? 'ALL' : 'ANY';
    final conditionWord = detail.conditions.length == 1 ? '' : 's';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 6,
          children: [
            _Pill(violated: detail.violated),
            Text(
              'Matches $logicLabel condition$conditionWord below · Last evaluated $lastEvaluatedLabel',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (detail.conditions.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('This policy has no conditions configured.',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          )
        else
          ...detail.conditions.map((c) => _ConditionRow(condition: c)),
        const SizedBox(height: 12),
        Text(
          'Red means this specific condition currently matches on this device '
          '(it\'s contributing to the policy\'s violation); green means it '
          'doesn\'t. With "ANY" logic, one red condition is enough to violate '
          'the policy; with "ALL" logic, every condition needs to be red for '
          'the policy to be violated.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  String _formatTimestamp(String iso) {
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year}, '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.violated});
  final bool violated;

  @override
  Widget build(BuildContext context) {
    final color = violated ? AppColors.danger : AppColors.success;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(violated ? 'Violating' : 'Compliant',
          style: TextStyle(
              color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class _ConditionRow extends StatelessWidget {
  const _ConditionRow({required this.condition});
  final PolicyCondition condition;

  @override
  Widget build(BuildContext context) {
    final color = condition.met ? AppColors.danger : AppColors.success;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.cardDark
            : AppColors.gray50,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(conditionLabel(condition),
                style: Theme.of(context).textTheme.bodyLarge),
          ),
        ],
      ),
    );
  }
}

/// Best-effort human-readable label for one condition — a lighter, self-
/// contained cousin of the web dashboard's conditionLabel
/// (DeviceCompliancePolicyStatusModal.vue). The web version resolves field
/// keys against a fetched compliance-fields catalog (name/type per field,
/// e.g. "smart_attribute" vs "boolean") to pick a type-specific phrasing;
/// this app has no such catalog call, so it falls back to humanizing the raw
/// field key (camelCase/snake_case -> Title Case words) instead of a curated
/// label, and skips the catalog-dependent type-specific branches (smart/
/// self-reported attribute, custom field, duration, boolean). Still covers
/// the common shapes: exists/missing with a named sub-attribute, array
/// values, object values with a name, and the plain scalar case — which is
/// what the great majority of conditions actually are.
const Map<String, String> _operatorLabel = {
  'equals': 'is',
  'notEquals': 'is not',
  'greaterThan': 'is more than',
  'lessThan': 'is less than',
  'includes': 'has',
  'excludes': "doesn't have",
  'missing': 'is missing',
  'contains': 'contains',
  'exists': 'exists',
  'inside': 'is inside',
  'outside': 'is outside',
};

String conditionLabel(PolicyCondition c) {
  final label = _humanizeFieldKey(c.field);
  final opLabel = _operatorLabel[c.operator] ?? c.operator;
  final value = c.value;

  if (c.operator == 'exists' || c.operator == 'missing') {
    final subName =
        value is Map ? (value['name'] ?? value['key'] ?? value['path']) : null;
    return subName != null ? '$label "$subName" $opLabel' : '$label $opLabel';
  }
  if (value is List) {
    return '$label $opLabel ${value.join(', ')}';
  }
  if (value is Map) {
    final named = value['name'] ?? value['policyName'];
    return '$label $opLabel ${named ?? value}';
  }
  if (value == null || value == '') return '$label $opLabel';
  return '$label $opLabel $value';
}

String _humanizeFieldKey(String key) {
  if (key.isEmpty) return key;
  // snake_case -> spaces, then split camelCase word boundaries.
  final spaced = key.replaceAll('_', ' ');
  final words = spaced
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty);
  return words.map((w) => w[0].toUpperCase() + w.substring(1)).join(' ');
}
