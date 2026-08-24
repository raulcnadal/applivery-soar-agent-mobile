import 'dart:async';

import 'package:flutter/material.dart';

import '../checks/integrity.dart';
import '../config/managed_config.dart';

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

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _runIntegrityCheck();
    _configSub = ManagedConfigChannel.instance.watch().listen(
      (config) => setState(() => _config = config),
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
