import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../config/managed_config.dart';

/// Outcome of an enrollment attempt — mirrors the shape the eventual
/// compliance status screen will want to show (ARCHITECTURE.md §0.2), not
/// just a bool.
class MtlsEnrollmentResult {
  const MtlsEnrollmentResult.success({required this.notAfter})
      : isEnrolled = true,
        error = null;
  const MtlsEnrollmentResult.failure(this.error)
      : isEnrolled = false,
        notAfter = null;

  final bool isEnrolled;
  final String? notAfter;
  final String? error;
}

/// Result of a low-level mTLS-authenticated HTTP call — deliberately just
/// status code + raw body, with no opinion about the response shape. Callers
/// like AgentStatusClient (lib/api/agent_status_client.dart) decode the JSON
/// themselves; this class only wraps what the native `mtlsRequest` channel
/// method returns.
class MtlsHttpResponse {
  const MtlsHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// Thrown when the native `mtlsRequest` call itself fails (TLS handshake
/// error, no identity enrolled yet, DNS/connect failure, timeout) — distinct
/// from a non-2xx [MtlsHttpResponse], which is a successful call that the
/// server responded to with an error status.
class MtlsRequestException implements Exception {
  MtlsRequestException(this.message);
  final String message;

  @override
  String toString() => 'MtlsRequestException: $message';
}

/// Dart-side orchestration for mTLS device identity — the actual
/// POST /api/device-mtls/register HTTP call (backend deviceMtls.service.ts
/// / deviceMtls.controller.ts), talking to the native CSR-generation
/// plugins (android/.../MtlsIdentityPlugin.kt, ios/Runner/MtlsIdentityPlugin.swift)
/// for the on-device crypto only. Mirrors the desktop agents'
/// registerMtlsIdentity (mtls_macos.go/mtls_windows.go): plain (non-mTLS)
/// HTTP client since the device has no certificate yet, X-Workspace-Slug +
/// X-Bootstrap-Token headers, {csrPem, serialNumber} body, and a
/// {certPem, caCertPem, notAfter} response.
///
/// Also wraps `mtlsRequest`, the native platform-channel method both plugins
/// now expose for making an actual mTLS-authenticated HTTPS call bound to
/// the stored hardware-backed identity (iOS: URLSession delegate presenting
/// the Keychain SecIdentity; Android: KeyManagerFactory scoped to the
/// AndroidKeyStore alias) — used today by AgentStatusClient
/// (lib/api/agent_status_client.dart) for GET /api/device-data/agent-status,
/// and the same primitive POST /api/device-mtls/renew will eventually reuse.
class MtlsIdentity {
  MtlsIdentity._();
  static final MtlsIdentity instance = MtlsIdentity._();

  static const MethodChannel _channel =
      MethodChannel('es.applivery.soar/mtls_identity');

  /// Whether a certificate has already been issued and stored natively —
  /// checked before attempting a fresh registration, since the backend
  /// rejects re-registering a serial that already has an active certificate
  /// (deviceMtls.service.ts' assertNotAlreadyActive) and there's no reason
  /// to burn a fresh CSR generation on a device that's already enrolled.
  Future<bool> hasIdentity() async {
    final result = await _channel.invokeMethod<bool>('hasIdentity');
    return result ?? false;
  }

  /// Runs the full first-time enrollment flow: generate a CSR natively
  /// (commonName is advisory only — the backend ignores whatever CN a CSR
  /// claims and forces it to [ManagedConfig.deviceSerial] regardless, same
  /// as the desktop agents), POST it to /api/device-mtls/register, and hand
  /// the issued certificate back to the native side to store.
  ///
  /// Requires [ManagedConfig.canEnroll] — callers should check that first
  /// and surface why enrollment can't proceed (missing bootstrap token vs.
  /// missing device serial are different admin-facing problems) rather than
  /// relying on this method's generic failure message.
  Future<MtlsEnrollmentResult> enroll(ManagedConfig config) async {
    if (!config.canEnroll) {
      return const MtlsEnrollmentResult.failure(
        'Managed Configuration is incomplete — workspace_slug, base_url, bootstrap_token, and device_serial are all required to enroll.',
      );
    }

    final String csrPem;
    try {
      csrPem = await _generateCsr(config.deviceSerial!);
    } catch (error) {
      return MtlsEnrollmentResult.failure(
          'Could not generate a CSR on-device: $error');
    }

    final registerUri = Uri.parse(config.registerUrl ?? config.baseUrl)
        .resolve('/api/device-mtls/register');
    final http.Response response;
    try {
      response = await http
          .post(
            registerUri,
            headers: {
              'Content-Type': 'application/json',
              'X-Workspace-Slug': config.workspaceSlug,
              'X-Bootstrap-Token': config.bootstrapToken!,
            },
            body: jsonEncode(
                {'csrPem': csrPem, 'serialNumber': config.deviceSerial}),
          )
          .timeout(const Duration(seconds: 30));
    } catch (error) {
      return MtlsEnrollmentResult.failure(
          'Registration request failed: $error');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return MtlsEnrollmentResult.failure(
          'Backend rejected registration (HTTP ${response.statusCode}): ${_bodySnippet(response.body)}');
    }

    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (error) {
      return MtlsEnrollmentResult.failure(
          'Could not parse registration response: $error');
    }

    final certPem = decoded['certPem'] as String?;
    final caCertPem = decoded['caCertPem'] as String?;
    final notAfter = decoded['notAfter'] as String?;
    if (certPem == null || certPem.isEmpty) {
      return const MtlsEnrollmentResult.failure(
          'Registration response had no certPem.');
    }

    try {
      await _storeCertificate(certPem, caCertPem);
    } catch (error) {
      return MtlsEnrollmentResult.failure(
          'Certificate issued but could not be stored on-device: $error');
    }

    return MtlsEnrollmentResult.success(notAfter: notAfter);
  }

  /// Deletes the on-device key/certificate — for testing re-enrollment
  /// locally, or if a device needs to be reset. Does NOT revoke the
  /// certificate backend-side; that's an admin action from Settings.
  Future<void> clearIdentity() => _channel.invokeMethod('clearIdentity');

  Future<String> _generateCsr(String commonName) async {
    final result = await _channel
        .invokeMethod<String>('generateCsr', {'commonName': commonName});
    if (result == null || result.isEmpty) {
      throw StateError('Native side returned an empty CSR.');
    }
    return result;
  }

  Future<void> _storeCertificate(String certPem, String? caCertPem) async {
    await _channel.invokeMethod('storeCertificate', {
      'certPem': certPem,
      if (caCertPem != null && caCertPem.isNotEmpty) 'caCertPem': caCertPem,
    });
  }

  /// Makes an mTLS-authenticated HTTP request through the native
  /// `mtlsRequest` method, presenting the stored hardware-backed identity as
  /// the TLS client certificate. Requires [hasIdentity] to be true first —
  /// both native implementations throw a clear error otherwise rather than
  /// silently falling back to an unauthenticated request, since a caller
  /// treating an unauthenticated 401/403 as "not compliant" would be
  /// actively misleading.
  ///
  /// Deliberately generic (method/url/headers/body in, status/body out) so
  /// it covers every device-data endpoint mobile will ever need to call
  /// (agent-status today, report/report-apps/renew later) without adding a
  /// new native method per endpoint.
  Future<MtlsHttpResponse> request({
    required String method,
    required Uri url,
    Map<String, String>? headers,
    String? body,
  }) async {
    final Map<Object?, Object?>? result;
    try {
      result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'mtlsRequest',
        {
          'method': method,
          'url': url.toString(),
          if (headers != null) 'headers': headers,
          if (body != null) 'body': body,
        },
      );
    } on PlatformException catch (error) {
      throw MtlsRequestException(error.message ?? error.code);
    }

    if (result == null) {
      throw MtlsRequestException('Native side returned no response.');
    }
    final statusCode = result['statusCode'] as int? ?? 0;
    final responseBody = result['body'] as String? ?? '';
    return MtlsHttpResponse(statusCode: statusCode, body: responseBody);
  }

  String _bodySnippet(String body) =>
      body.length > 300 ? '${body.substring(0, 300)}…' : body;
}
