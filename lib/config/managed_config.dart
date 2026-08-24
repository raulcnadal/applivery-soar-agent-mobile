import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Mirrors the Managed Configuration schema documented in ARCHITECTURE.md —
/// the mobile analog of the Windows registry policy / macOS preferences
/// plist each desktop agent reads its own Config from. Delivered here via
/// Android's App Restrictions / iOS's Managed App Configuration, both pushed
/// by Applivery UEM as this app's MDM once it's assigned to a device.
///
/// Deliberately mTLS-only (no legacy report_secret field, unlike the
/// desktop agents' Config) — see ARCHITECTURE.md §0: there's no existing
/// mobile agent deployment to stay backward compatible with, so this starts
/// clean on the identity model the desktop agents only adopted later.
class ManagedConfig {
  const ManagedConfig({
    required this.workspaceSlug,
    required this.baseUrl,
    this.deviceSerial,
    this.registerUrl,
    this.bootstrapToken,
    this.intervalSec = 3600,
    this.reportIntegrity = true,
  });

  /// The Applivery workspace this device reports into.
  final String workspaceSlug;

  /// This device's real hardware serial number — the same value the backend
  /// matches against Applivery's own live fleet (deviceMtls.service.ts'
  /// assertKnownApplivertyDevice) and the same value the desktop agents read
  /// directly off the OS (GetSerialNumber() in the macOS/Windows repos).
  /// Neither iOS nor Android exposes a real serial number to an app running
  /// on-device — Apple has blocked it outright since iOS 7, and Android
  /// restricts Build.getSerial() to system/privileged callers — so this
  /// can ONLY arrive via Managed Configuration, sourced from Applivery's own
  /// `{{device.serialNumber}}` interpolation tag (confirmed supported in
  /// device configuration profiles/policies — see
  /// https://docs.applivery.com/en/device-management/general-settings/dynamic-variables-interpolation-tags/).
  /// An admin setting this app's Managed App Configuration in Applivery must
  /// set the `device_serial` field's VALUE to the literal string
  /// `{{device.serialNumber}}`, not a hardcoded value — Applivery
  /// substitutes the real per-device serial at push time.
  final String? deviceSerial;

  /// SOAR backend base URL — e.g. https://soar.yourcompany.com. Required;
  /// unlike the desktop agents there's no installer-baked default, since a
  /// mobile app build isn't produced per-tenant the way an MSI/pkg is.
  final String baseUrl;

  /// Optional override for the mTLS enrollment endpoint only
  /// (POST /api/device-mtls/register). Falls back to [baseUrl] when empty —
  /// same RegisterURL semantics as the Windows/macOS agents' Config (see
  /// macOS agent's config.go), for the same reason: a workspace using mTLS
  /// needs a separate cert-verifying vhost for /report and /renew, but
  /// /register never presents a client certificate and doesn't need that
  /// vhost's health at all.
  final String? registerUrl;

  /// The Global Bootstrap Token — same value pushed to every device in the
  /// fleet, consumed exactly once on this device's first successful mTLS
  /// registration. Harmless to leave in place after that.
  final String? bootstrapToken;

  /// How often to run the report cycle once one exists (default 1 hour,
  /// matching the desktop agents' own default).
  final int intervalSec;

  /// Whether to run the jailbreak/root integrity check at all — an admin
  /// escape hatch in case a specific fleet needs it disabled (e.g. false
  /// positives on a particular OEM/ROM), mirroring the desktop agents'
  /// per-signal report_* toggles (report_filevault, report_firewall, ...).
  final bool reportIntegrity;

  /// Enough Managed Configuration to do anything — same shape as the
  /// desktop agents' Config.IsConfigured().
  bool get isConfigured =>
      workspaceSlug.isNotEmpty &&
      baseUrl.isNotEmpty &&
      (bootstrapToken?.isNotEmpty ?? false);

  /// Enough to actually attempt mTLS enrollment specifically — a stricter
  /// check than [isConfigured], since registration additionally needs
  /// [deviceSerial] (see its own doc comment for why that's a separate,
  /// easy-to-forget-when-setting-up-Applivery field rather than something
  /// this app can always fill in on its own).
  bool get canEnroll => isConfigured && (deviceSerial?.isNotEmpty ?? false);

  static const ManagedConfig empty =
      ManagedConfig(workspaceSlug: '', baseUrl: '');

  factory ManagedConfig.fromMap(Map<Object?, Object?> map) {
    String? readString(String key) {
      final value = map[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    int readInt(String key, int fallback) {
      final value = map[key];
      if (value is int) return value;
      if (value is String) return int.tryParse(value) ?? fallback;
      return fallback;
    }

    bool readBool(String key, bool fallback) {
      final value = map[key];
      if (value is bool) return value;
      if (value is String) return value.toLowerCase() == 'true';
      return fallback;
    }

    return ManagedConfig(
      workspaceSlug: readString('workspace_slug') ?? '',
      baseUrl: readString('base_url') ?? '',
      deviceSerial: readString('device_serial'),
      registerUrl: readString('register_url'),
      bootstrapToken: readString('bootstrap_token'),
      intervalSec: readInt('interval_sec', 3600),
      reportIntegrity: readBool('report_integrity', true),
    );
  }

  @override
  String toString() =>
      'ManagedConfig(workspaceSlug: $workspaceSlug, baseUrl: $baseUrl, deviceSerial: $deviceSerial, '
      'registerUrl: $registerUrl, bootstrapToken: ${bootstrapToken == null ? 'null' : '<redacted>'}, '
      'intervalSec: $intervalSec, reportIntegrity: $reportIntegrity)';
}

/// Bridges the native Managed Config channels — see
/// android/app/src/main/kotlin/com/applivery/soar/mobile/ManagedConfigPlugin.kt
/// and ios/Runner/ManagedConfigPlugin.swift for the two platform-specific
/// readers this wraps. Both expose the identical channel names/method/event
/// contract so this class doesn't need any platform branching of its own.
class ManagedConfigChannel {
  ManagedConfigChannel._();
  static final ManagedConfigChannel instance = ManagedConfigChannel._();

  static const MethodChannel _method =
      MethodChannel('es.applivery.soar/managed_config');
  static const EventChannel _events =
      EventChannel('es.applivery.soar/managed_config_stream');

  /// One-shot read of the config as it stands right now.
  ///
  /// Debug builds only: if the real Managed Config channel comes back empty
  /// (the normal case on an unmanaged emulator/simulator/dev device — no
  /// real MDM has pushed anything), falls back to `--dart-define` values so
  /// local UI development doesn't require standing up a full Android Test
  /// DPC / Simulator UserDefaults setup just to see a populated screen. See
  /// README.md "Testing Managed Configuration locally" for exact commands —
  /// both this fallback AND the real native-channel end-to-end path (which
  /// this fallback deliberately bypasses and does NOT substitute for).
  Future<ManagedConfig> current() async {
    final raw =
        await _method.invokeMethod<Map<Object?, Object?>>('getManagedConfig');
    final config =
        raw == null ? ManagedConfig.empty : ManagedConfig.fromMap(raw);
    if (config.isConfigured || !kDebugMode) return config;
    return _debugDefineFallback();
  }

  static const _debugWorkspaceSlug =
      String.fromEnvironment('DEBUG_WORKSPACE_SLUG');
  static const _debugBaseUrl = String.fromEnvironment('DEBUG_BASE_URL');
  static const _debugBootstrapToken =
      String.fromEnvironment('DEBUG_BOOTSTRAP_TOKEN');
  static const _debugDeviceSerial =
      String.fromEnvironment('DEBUG_DEVICE_SERIAL');

  ManagedConfig _debugDefineFallback() {
    if (_debugWorkspaceSlug.isEmpty || _debugBaseUrl.isEmpty) {
      return ManagedConfig.empty;
    }
    return ManagedConfig(
      workspaceSlug: _debugWorkspaceSlug,
      baseUrl: _debugBaseUrl,
      bootstrapToken:
          _debugBootstrapToken.isEmpty ? null : _debugBootstrapToken,
      deviceSerial: _debugDeviceSerial.isEmpty ? null : _debugDeviceSerial,
    );
  }

  /// Live updates — fires whenever the MDM pushes a new Managed
  /// Configuration while the app is running, no restart required to pick up
  /// a changed bootstrap token or interval. Every native-side change (a
  /// broadcast on Android, any UserDefaults write on iOS) re-triggers a full
  /// re-read rather than diffing, so a caller may see an identical value
  /// fire more than once — treat this as "config might have changed,
  /// re-check", not "config definitely changed".
  Stream<ManagedConfig> watch() {
    return _events.receiveBroadcastStream().map((raw) {
      if (raw is Map) {
        return ManagedConfig.fromMap(raw.cast<Object?, Object?>());
      }
      return ManagedConfig.empty;
    });
  }
}
