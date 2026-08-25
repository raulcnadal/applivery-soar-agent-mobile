import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../config/managed_config.dart';
import '../identity/mtls_identity.dart';

/// Google Play Integrity API — mobile telemetry roadmap Phase 3, Android
/// only. Orchestrates the full on-device half of the flow documented in
/// playIntegrity.service.ts's module doc comment:
///
/// 1. GET /api/device-data/play-integrity/nonce?serialNumber=... (mTLS-gated,
///    same as every other device-facing call) — returns a fresh, single-use
///    nonce plus this workspace's Cloud Project Number.
/// 2. Native `requestToken` (PlayIntegrityPlugin.kt) makes the actual Play
///    Integrity Classic API call with that nonce + project number.
/// 3. The raw, still-encrypted/signed token is returned to
///    device_report_client.dart, which includes it as `playIntegrityToken`
///    on the next POST /api/device-data/report — decrypted/verified
///    entirely server-side, never here.
///
/// Deliberately best-effort end to end, same as
/// DeviceSecurityTelemetryChannel.collect(): a missing backend config (503
/// from issueNonce), a throttled native call, or any other failure all
/// resolve to `null` rather than throwing, so a Play Integrity hiccup never
/// blocks the rest of a report cycle. Android-only; iOS callers get `null`
/// immediately without attempting the mTLS round-trip at all.
class PlayIntegrityClient {
  PlayIntegrityClient._();
  static final PlayIntegrityClient instance = PlayIntegrityClient._();

  static const MethodChannel _channel =
      MethodChannel('es.applivery.soar/play_integrity');

  Future<String?> fetchToken(ManagedConfig config) async {
    if (!Platform.isAndroid) return null;
    if (config.deviceSerial == null || config.deviceSerial!.isEmpty) {
      return null;
    }

    final String nonce;
    final String cloudProjectNumber;
    try {
      final nonceUrl = Uri.parse(config.baseUrl).resolve(
          '/api/device-data/play-integrity/nonce?serialNumber=${Uri.encodeQueryComponent(config.deviceSerial!)}');
      final response = await MtlsIdentity.instance.request(
        method: 'GET',
        url: nonceUrl,
        headers: {'X-Workspace-Slug': config.workspaceSlug},
      );
      // A non-2xx here is most often "Google Play Integrity API isn't
      // configured for this workspace yet" (issueNonce's own 503) — an
      // entirely normal, expected state until an admin sets it up under
      // Settings, not worth logging as an error every report cycle.
      if (!response.isSuccess) return null;
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      nonce = decoded['nonce'] as String? ?? '';
      cloudProjectNumber = decoded['cloudProjectNumber'] as String? ?? '';
      if (nonce.isEmpty || cloudProjectNumber.isEmpty) return null;
    } catch (_) {
      return null;
    }

    try {
      final token = await _channel.invokeMethod<String>('requestToken', {
        'nonce': nonce,
        'cloudProjectNumber': cloudProjectNumber,
      });
      return token;
    } catch (_) {
      // Covers both a genuine native failure and the plugin's own
      // "THROTTLED" PlatformException (PlayIntegrityPlugin.kt) — either way,
      // simply skip Play Integrity for this report cycle.
      return null;
    }
  }
}
