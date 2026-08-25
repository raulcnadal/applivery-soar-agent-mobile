import 'dart:async';

import 'package:flutter/material.dart';

import '../about/about_screen.dart';
import '../api/agent_status_client.dart';
import '../checks/integrity.dart';
import '../config/managed_config.dart';
import '../identity/mtls_identity.dart';
import '../theme/design_tokens.dart';
import '../widgets/app_banner.dart';
import 'policy_detail_screen.dart';

/// The real compliance status screen — replaces the old dev-only
/// DebugScreen (ARCHITECTURE.md §0.2) now that there's a full path to real
/// data: Managed Config -> silent mTLS enrollment -> native
/// mTLS-authenticated GET /api/device-data/agent-status
/// (lib/identity/mtls_identity.dart's `request`, lib/api/agent_status_client.dart)
/// -> this screen.
///
/// Managed Config, the integrity check, and the device certificate's own
/// status are all genuinely useful for support, but not what most people
/// opening this app care about day to day — they're tucked into a hidden
/// "Diagnostics" menu (long-press the header logo, see _DiagnosticsDrawer)
/// rather than shown inline, keeping the main view focused on compliance
/// status and policies.
class ComplianceScreen extends StatefulWidget {
  const ComplianceScreen({super.key});

  @override
  State<ComplianceScreen> createState() => _ComplianceScreenState();
}

class _ComplianceScreenState extends State<ComplianceScreen> {
  ManagedConfig _config = ManagedConfig.empty;
  IntegrityCheckResult _integrity = IntegrityCheckResult.clean;
  bool _loadingConfig = true;
  bool _loadingIntegrity = true;
  Object? _configError;
  Object? _integrityError;
  StreamSubscription<ManagedConfig>? _configSub;

  bool? _hasIdentity;
  bool _enrolling = false;
  MtlsEnrollmentResult? _enrollResult;

  bool _loadingStatus = false;
  AgentStatusResult? _status;
  Object? _statusError;

  /// Config "fingerprint" (workspace + serial + token) of the last automatic
  /// enroll attempt — see debug_screen.dart's original doc comment for why
  /// this exists (enrollment must be silent on a managed device, but only
  /// auto-attempted once per distinct config value, not on every rebuild).
  String? _autoEnrollAttemptedFor;

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _runIntegrityCheck();
    _refreshIdentityStatus();
    _configSub = ManagedConfigChannel.instance.watch().listen(
      (config) {
        setState(() => _config = config);
        _maybeAutoEnroll();
      },
      onError: (Object error) => setState(() => _configError = error),
    );
  }

  @override
  void dispose() {
    _configSub?.cancel();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    setState(() {
      _loadingConfig = true;
      _configError = null;
    });
    try {
      final config = await ManagedConfigChannel.instance.current();
      setState(() => _config = config);
      _maybeAutoEnroll();
    } catch (error) {
      setState(() => _configError = error);
    } finally {
      setState(() => _loadingConfig = false);
    }
  }

  Future<void> _runIntegrityCheck() async {
    setState(() {
      _loadingIntegrity = true;
      _integrityError = null;
    });
    try {
      final result = await IntegrityChannel.instance.check();
      setState(() => _integrity = result);
    } catch (error) {
      setState(() => _integrityError = error);
    } finally {
      setState(() => _loadingIntegrity = false);
    }
  }

  Future<void> _refreshIdentityStatus() async {
    final has = await MtlsIdentity.instance.hasIdentity();
    if (!mounted) return;
    setState(() => _hasIdentity = has);
    _maybeAutoEnroll();
    if (has) await _fetchStatus();
  }

  Future<void> _enroll() async {
    setState(() {
      _enrolling = true;
      _enrollResult = null;
    });
    final result = await MtlsIdentity.instance.enroll(_config);
    if (!mounted) return;
    setState(() {
      _enrolling = false;
      _enrollResult = result;
    });
    if (result.isEnrolled) await _refreshIdentityStatus();
  }

  /// See debug_screen.dart's original doc comment on this same method —
  /// fires automatically whenever Managed Config becomes complete and no
  /// identity exists yet, gated to one attempt per distinct config value.
  /// The manual "Enroll now" retry lives in [_IdentityRow] below.
  void _maybeAutoEnroll() {
    if (_enrolling || _hasIdentity != false || !_config.canEnroll) return;
    final key =
        '${_config.workspaceSlug}|${_config.deviceSerial}|${_config.bootstrapToken}';
    if (_autoEnrollAttemptedFor == key) return;
    _autoEnrollAttemptedFor = key;
    unawaited(_enroll());
  }

  Future<void> _fetchStatus() async {
    setState(() {
      _loadingStatus = true;
      _statusError = null;
    });
    try {
      final status = await AgentStatusClient.instance.fetch(_config);
      if (!mounted) return;
      setState(() => _status = status);
    } catch (error) {
      if (!mounted) return;
      setState(() => _statusError = error);
    } finally {
      if (mounted) setState(() => _loadingStatus = false);
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([_loadConfig(), _runIntegrityCheck()]);
    await _refreshIdentityStatus();
  }

  @override
  Widget build(BuildContext context) {
    final enrolled = _hasIdentity ?? false;
    return Scaffold(
      appBar: AppBar(
        // Builder gives this title widget a context BELOW the Scaffold
        // being built here, which Scaffold.of(context) requires to find
        // it — the State's own `context` (this build method's parameter) is
        // an ancestor of the Scaffold instead, so it can't be used directly
        // for openEndDrawer().
        title: Builder(
          builder: (innerContext) => GestureDetector(
            onLongPress: () => Scaffold.of(innerContext).openEndDrawer(),
            child: Semantics(
                label: 'Applivery SOAR Agent', child: const AppBanner()),
          ),
        ),
      ),
      endDrawer: _DiagnosticsDrawer(
        config: _config,
        hasIdentity: _hasIdentity,
        enrolling: _enrolling,
        enrollResult: _enrollResult,
        onEnroll: _enroll,
        loadingConfig: _loadingConfig,
        configError: _configError,
        integrity: _integrity,
        loadingIntegrity: _loadingIntegrity,
        integrityError: _integrityError,
      ),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _DeviceHeaderCard(
              status: _status,
              loading: _loadingStatus,
              error: _statusError,
              identityEnrolled: enrolled,
              onRetry: _fetchStatus,
            ),
            const SizedBox(height: 16),
            if (_status?.compliance.available == true)
              _CompliancePoliciesCard(
                compliance: _status!.compliance,
                config: _config,
              ),
          ],
        ),
      ),
    );
  }
}

/// Top-of-screen summary: device name (once matched) plus a status pill —
/// "Compliant" / "Non-compliant" / "Unavailable" / "Checking…" — the same
/// four states the Windows tray card and macOS menu-bar card show (see
/// tray/card.go, StatusCardView.swift), so a mixed fleet reads consistently.
class _DeviceHeaderCard extends StatelessWidget {
  const _DeviceHeaderCard({
    required this.status,
    required this.loading,
    required this.error,
    required this.identityEnrolled,
    required this.onRetry,
  });

  final AgentStatusResult? status;
  final bool loading;
  final Object? error;
  final bool identityEnrolled;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final compliance = status?.compliance;
    final _StatusPresentation presentation = _presentationFor(
      identityEnrolled: identityEnrolled,
      loading: loading,
      error: error,
      compliance: compliance,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                      color: presentation.color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status?.deviceDisplayName ?? 'This device',
                    style: Theme.of(context).textTheme.titleLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: loading ? null : onRetry),
              ],
            ),
            const SizedBox(height: 4),
            Text(presentation.label,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: presentation.color)),
            if (compliance?.riskTier != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  _Badge(
                      label: 'Risk: ${compliance!.riskTier}',
                      color: tierColor(compliance.riskTier)),
                  if (compliance.riskScore != null) ...[
                    const SizedBox(width: 8),
                    _Badge(
                        label: 'Score ${compliance.riskScore}',
                        color: AppColors.gray400),
                  ],
                ],
              ),
            ],
            if (compliance != null &&
                !compliance.available &&
                compliance.reason != null) ...[
              const SizedBox(height: 8),
              Text(compliance.reason!,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            // Only shown once actually enrolled — a compliance-fetch error
            // left over from a previous attempt is meaningless (and
            // misleading) once the real, current blocker is simply "no
            // certificate yet"; the identity row below already explains
            // that case on its own.
            if (identityEnrolled && error != null) ...[
              const SizedBox(height: 8),
              Text(_errorMessage(error!),
                  style: const TextStyle(color: AppColors.danger)),
            ],
          ],
        ),
      ),
    );
  }

  String _errorMessage(Object error) {
    if (error is AgentStatusException) {
      if (error.likelyMtlsNotEnforced) {
        return 'Could not reach compliance status — ask your Applivery admin to enable mTLS enforcement '
            'for this workspace (Settings → mTLS Authentication).';
      }
      return error.message;
    }
    return '$error';
  }

  _StatusPresentation _presentationFor({
    required bool identityEnrolled,
    required bool loading,
    required Object? error,
    required AgentComplianceStatus? compliance,
  }) {
    if (!identityEnrolled) {
      return const _StatusPresentation(
          label: 'Not enrolled yet', color: AppColors.gray400);
    }
    if (loading && compliance == null) {
      return const _StatusPresentation(
          label: 'Checking…', color: AppColors.gray400);
    }
    if (error != null && compliance == null) {
      return const _StatusPresentation(
          label: 'Status unavailable', color: AppColors.warning);
    }
    if (compliance == null || !compliance.available) {
      return const _StatusPresentation(
          label: 'Compliance unavailable', color: AppColors.gray400);
    }
    if (compliance.compliant == true) {
      return const _StatusPresentation(
          label: 'Compliant', color: AppColors.success);
    }
    return const _StatusPresentation(
        label: 'Non-compliant', color: AppColors.danger);
  }
}

class _StatusPresentation {
  const _StatusPresentation({required this.label, required this.color});
  final String label;
  final Color color;
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        // withOpacity is deprecated on this SDK version (confirmed by
        // `flutter analyze` itself) — withValues(alpha:) is its replacement,
        // avoids the precision-loss warning, and is what's actually
        // supported here.
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

/// Applicable policies + any active violations — the two lists
/// `AgentStatusResponse.compliance` carries once `available` is true.
/// Each row is tappable, opening [PolicyDetailScreen] for that policy's
/// per-condition red/green breakdown (GET /api/device-data/compliance-policy
/// — see that screen's own doc comment).
class _CompliancePoliciesCard extends StatelessWidget {
  const _CompliancePoliciesCard(
      {required this.compliance, required this.config});
  final AgentComplianceStatus compliance;
  final ManagedConfig config;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Compliance Policies',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            if (compliance.policies.isEmpty)
              Text('No policies apply to this platform.',
                  style: Theme.of(context).textTheme.bodySmall)
            else
              ...compliance.policies.map((policy) {
                final violation = compliance.violations
                    .where((v) => v.policyId == policy.id)
                    .cast<AgentPolicyViolation?>()
                    .firstWhere((_) => true, orElse: () => null);
                return InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PolicyDetailScreen(
                        config: config,
                        policyId: policy.id,
                        policyName: policy.name,
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          violation != null
                              ? Icons.error_outline
                              : Icons.check_circle_outline,
                          size: 18,
                          color: violation != null
                              ? AppColors.danger
                              : AppColors.success,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(policy.name),
                              if (violation != null)
                                Text(
                                  violation.lastDetectedAt != null
                                      ? 'Violated — last detected ${violation.lastDetectedAt}'
                                      : 'Violated',
                                  style: const TextStyle(
                                      color: AppColors.danger, fontSize: 12),
                                ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right,
                            size: 18, color: AppColors.gray400),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

/// Compact identity/enrollment row — enrollment itself is silent (see
/// _maybeAutoEnroll above), so this is deliberately small: a status line
/// plus a manual retry button that only appears once there's something to
/// retry (config complete, not yet enrolled).
class _IdentityRow extends StatelessWidget {
  const _IdentityRow({
    required this.config,
    required this.hasIdentity,
    required this.enrolling,
    required this.result,
    required this.onEnroll,
  });

  final ManagedConfig config;
  final bool? hasIdentity;
  final bool enrolling;
  final MtlsEnrollmentResult? result;
  final VoidCallback onEnroll;

  @override
  Widget build(BuildContext context) {
    final enrolled = hasIdentity ?? false;
    // Surfaced separately from the status line below — a failed enroll
    // attempt (bad network, backend rejected the CSR, native storage error)
    // used to be silently swallowed here: the old DebugScreen's _IdentityCard
    // showed `result.error` directly, and that got dropped when this was
    // condensed into a compact row. Without it there's no way to tell "auto
    // -enroll hasn't run yet" apart from "auto-enroll ran and failed," which
    // matters a lot when diagnosing why a device never gets a certificate.
    final failureMessage =
        (result != null && !result!.isEnrolled) ? result!.error : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  enrolled ? Icons.verified_user : Icons.no_accounts,
                  size: 18,
                  color: enrolled ? AppColors.success : AppColors.gray400,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hasIdentity == null
                        ? 'Checking device certificate…'
                        : enrolled
                            ? 'Device certificate valid'
                            : enrolling
                                ? 'Enrolling…'
                                : config.canEnroll
                                    ? 'Not enrolled'
                                    : 'Waiting for Managed Configuration',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                if (!enrolled && !enrolling && config.canEnroll)
                  TextButton(onPressed: onEnroll, child: const Text('Retry')),
                if (enrolling)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (failureMessage != null) ...[
              const SizedBox(height: 8),
              Text('Failed: $failureMessage',
                  style:
                      const TextStyle(color: AppColors.danger, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Hidden sliding menu — opened by long-pressing the header logo (see
/// ComplianceScreen's AppBar title Builder/GestureDetector above). Holds
/// everything that used to sit inline in the main view but isn't what most
/// people opening this app are here for: the device certificate/enrollment
/// status (formerly _IdentityRow, shown inline) and the Managed
/// Configuration + integrity check (formerly _DiagnosticsSection, shown as
/// a collapsed ExpansionTile). Both are now always-expanded plain content
/// here rather than re-collapsed — the menu itself is already the "tucked
/// away" layer, a second collapse inside it would just be friction. An
/// "About" link sits at the very bottom, per its own request.
class _DiagnosticsDrawer extends StatelessWidget {
  const _DiagnosticsDrawer({
    required this.config,
    required this.hasIdentity,
    required this.enrolling,
    required this.enrollResult,
    required this.onEnroll,
    required this.loadingConfig,
    required this.configError,
    required this.integrity,
    required this.loadingIntegrity,
    required this.integrityError,
  });

  final ManagedConfig config;
  final bool? hasIdentity;
  final bool enrolling;
  final MtlsEnrollmentResult? enrollResult;
  final VoidCallback onEnroll;
  final bool loadingConfig;
  final Object? configError;
  final IntegrityCheckResult integrity;
  final bool loadingIntegrity;
  final Object? integrityError;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      // Material's Drawer defaults to min(screenWidth - 56, 304) — sized for
      // a nav drawer that leaves a sliver of the previous screen visible at
      // its edge. This is a full settings-style menu, not primary nav, and
      // reads badly as a half-width strip on a portrait phone — full width
      // instead.
      width: MediaQuery.sizeOf(context).width,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text('Diagnostics',
                  style: Theme.of(context).textTheme.headlineMedium),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _IdentityRow(
                config: config,
                hasIdentity: hasIdentity,
                enrolling: enrolling,
                result: enrollResult,
                onEnroll: onEnroll,
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _DiagnosticsContent(
                config: config,
                loadingConfig: loadingConfig,
                configError: configError,
                integrity: integrity,
                loadingIntegrity: loadingIntegrity,
                integrityError: integrityError,
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About'),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AboutScreen()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Managed Config + integrity check — the same content _DiagnosticsSection
/// used to fold into a collapsed ExpansionTile inline; now always-expanded
/// content inside _DiagnosticsDrawer above (see that class's doc comment for
/// why the collapsing was dropped).
class _DiagnosticsContent extends StatelessWidget {
  const _DiagnosticsContent({
    required this.config,
    required this.loadingConfig,
    required this.configError,
    required this.integrity,
    required this.loadingIntegrity,
    required this.integrityError,
  });

  final ManagedConfig config;
  final bool loadingConfig;
  final Object? configError;
  final IntegrityCheckResult integrity;
  final bool loadingIntegrity;
  final Object? integrityError;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Managed Configuration',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (configError != null)
              Text('Error: $configError',
                  style: const TextStyle(color: AppColors.danger))
            else if (config.isConfigured) ...[
              _kv('Workspace', config.workspaceSlug),
              _kv('Base URL', config.baseUrl),
              _kv('Device serial', config.deviceSerial ?? 'not set'),
              _kv('Register URL', config.registerUrl ?? '(same as base URL)'),
              _kv('Bootstrap token',
                  config.bootstrapToken == null ? 'not set' : 'configured'),
              _kv('Report interval', '${config.intervalSec}s'),
              _kv('Report integrity checks',
                  config.reportIntegrity ? 'on' : 'off'),
            ] else
              const Text(
                'Not configured — no Managed Configuration found yet. Expected on an '
                'unmanaged device/simulator; see README.md for how to seed test values locally.',
              ),
            const SizedBox(height: 16),
            Text('Integrity check',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (integrityError != null)
              Text('Error: $integrityError',
                  style: const TextStyle(color: AppColors.danger))
            else ...[
              _kv('Status',
                  integrity.isCompromised ? 'Signals found' : 'Clean'),
              if (integrity.signals.isNotEmpty)
                ...integrity.signals.map(
                  (signal) => Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('• $signal',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 140,
              child: Text(label,
                  style: const TextStyle(color: AppColors.gray500))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
