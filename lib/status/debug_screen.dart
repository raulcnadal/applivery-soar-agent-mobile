import 'dart:async';

import 'package:flutter/material.dart';

import '../checks/integrity.dart';
import '../config/managed_config.dart';
import '../identity/mtls_identity.dart';

/// Dev-only visibility screen — not the real compliance status UI planned
/// in ARCHITECTURE.md (§0.2), just a way to see the two platform channels
/// (Managed Config, integrity check) are actually wired up correctly when
/// running locally. Replace with the real status screen once there's a
/// backend endpoint to back it (ARCHITECTURE.md §3).
class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
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

  /// Config "fingerprint" (workspace + serial + token) of the last automatic
  /// enroll attempt, so a real managed-app-config device silently enrolls
  /// itself the moment it has everything it needs — no button press
  /// required — without re-attempting on every single rebuild/stream tick if
  /// that attempt failed. The "Enroll now" button below is unaffected by
  /// this and stays available for a manual retry regardless.
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

  Future<void> _refreshIdentityStatus() async {
    final has = await MtlsIdentity.instance.hasIdentity();
    if (!mounted) return;
    setState(() => _hasIdentity = has);
    _maybeAutoEnroll();
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

  /// Enrollment is meant to be silent on a managed device — Applivery pushes
  /// Managed Config, the app reads it, and it should enroll on its own the
  /// next time it's opened, the same way the desktop agents self-register
  /// without an admin clicking anything. This fires automatically whenever
  /// Managed Config becomes complete (`canEnroll`) and no certificate exists
  /// yet, gated so it only auto-attempts once per distinct config value —
  /// see `_autoEnrollAttemptedFor` above. The "Enroll now" button stays as a
  /// manual fallback for retrying after a failure (bad network, backend
  /// briefly down, etc.) without waiting for the config to change again.
  void _maybeAutoEnroll() {
    if (_enrolling || _hasIdentity != false || !_config.canEnroll) return;
    final key = '${_config.workspaceSlug}|${_config.deviceSerial}|${_config.bootstrapToken}';
    if (_autoEnrollAttemptedFor == key) return;
    _autoEnrollAttemptedFor = key;
    unawaited(_enroll());
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Applivery SOAR Agent')),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([_loadConfig(), _runIntegrityCheck()]);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SectionCard(
              title: 'Managed Configuration',
              subtitle: 'Pushed by Applivery UEM. Live-updates automatically.',
              loading: _loadingConfig,
              error: _configError,
              onRetry: _loadConfig,
              children: _config.isConfigured
                  ? [
                      _kv('Workspace', _config.workspaceSlug),
                      _kv('Base URL', _config.baseUrl),
                      _kv('Device serial', _config.deviceSerial ?? 'not set'),
                      _kv('Register URL', _config.registerUrl ?? '(same as base URL)'),
                      _kv('Bootstrap token', _config.bootstrapToken == null ? 'not set' : 'configured'),
                      _kv('Report interval', '${_config.intervalSec}s'),
                      _kv('Report integrity checks', _config.reportIntegrity ? 'on' : 'off'),
                    ]
                  : [
                      const Text(
                        'Not configured — no Managed Configuration found yet. Expected on an '
                        'unmanaged device/simulator; see README.md for how to seed test values '
                        'locally.',
                      ),
                    ],
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Integrity check',
              subtitle: 'Jailbreak/root heuristic — best-effort, see native source doc comments.',
              loading: _loadingIntegrity,
              error: _integrityError,
              onRetry: _runIntegrityCheck,
              children: [
                _kv('Status', _integrity.isCompromised ? 'Signals found' : 'Clean'),
                if (_integrity.signals.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ..._integrity.signals.map(
                    (signal) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('• $signal', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            _IdentityCard(
              config: _config,
              hasIdentity: _hasIdentity,
              enrolling: _enrolling,
              result: _enrollResult,
              onEnroll: _enroll,
              onRefreshStatus: _refreshIdentityStatus,
            ),
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
          SizedBox(width: 140, child: Text(label, style: const TextStyle(color: Colors.grey))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.config,
    required this.hasIdentity,
    required this.enrolling,
    required this.result,
    required this.onEnroll,
    required this.onRefreshStatus,
  });

  final ManagedConfig config;
  final bool? hasIdentity;
  final bool enrolling;
  final MtlsEnrollmentResult? result;
  final VoidCallback onEnroll;
  final VoidCallback onRefreshStatus;

  @override
  Widget build(BuildContext context) {
    final enrolled = hasIdentity ?? false;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('mTLS identity', style: Theme.of(context).textTheme.titleMedium)),
                IconButton(icon: const Icon(Icons.refresh), onPressed: onRefreshStatus),
              ],
            ),
            Text(
              'Enrolls automatically once Managed Config is complete — no button press needed on a real '
              'managed device. "Enroll now" below is a manual retry. Registration only, per ARCHITECTURE.md — '
              'renewal isn\'t implemented yet.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(enrolled ? Icons.verified_user : Icons.no_accounts, size: 18, color: enrolled ? Colors.green : Colors.grey),
                const SizedBox(width: 8),
                Text(
                  hasIdentity == null
                      ? 'Checking…'
                      : enrolled
                          ? 'Certificate present on-device'
                          : 'Not enrolled',
                ),
              ],
            ),
            if (!config.canEnroll) ...[
              const SizedBox(height: 8),
              const Text(
                'Cannot enroll — Managed Configuration is missing workspace_slug, base_url, '
                'bootstrap_token, or device_serial.',
                style: TextStyle(color: Colors.orange),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: (!config.canEnroll || enrolled || enrolling) ? null : onEnroll,
              child: enrolling
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Enroll now'),
            ),
            if (result != null) ...[
              const SizedBox(height: 12),
              if (result!.isEnrolled)
                Text('Enrolled — certificate valid until ${result!.notAfter}.', style: const TextStyle(color: Colors.green))
              else
                Text('Failed: ${result!.error}', style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.children,
  });

  final String title;
  final String subtitle;
  final bool loading;
  final Object? error;
  final VoidCallback onRetry;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: Theme.of(context).textTheme.titleMedium),
                ),
                if (loading) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                IconButton(icon: const Icon(Icons.refresh), onPressed: loading ? null : onRetry),
              ],
            ),
            Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            if (error != null) Text('Error: $error', style: const TextStyle(color: Colors.red)) else ...children,
          ],
        ),
      ),
    );
  }
}
