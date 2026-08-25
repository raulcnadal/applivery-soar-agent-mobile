import Foundation
import Security

/// mTLS device identity — Keychain-backed EC keypair generation and
/// hand-rolled PKCS#10 CSR building (RFC 2986) for
/// POST /api/device-mtls/register (backend deviceMtls.service.ts). See
/// android/app/src/main/kotlin/.../MtlsIdentityPlugin.kt for the Android
/// equivalent (AndroidKeyStore + Bouncy Castle) and
/// lib/identity/mtls_identity.dart for the Dart orchestration that calls
/// this — this plugin ONLY does the on-device crypto, deliberately: the
/// private key is generated with kSecAttrIsPermanent (Keychain-resident)
/// and never leaves this process as raw key material — only PEM-encoded
/// CSRs and certificates (public data) ever cross the platform channel.
///
/// Hand-rolled DER/ASN.1 encoding, not a third-party CSR library: adding a
/// new Swift Package dependency to this Xcode project needs Xcode's own
/// package resolution (network access this sandbox doesn't have, and no
/// existing Package.swift/Podfile here to add one to safely by hand —
/// unlike the Android side, where Gradle resolves a new dependency
/// automatically on the user's next real build). The PKCS#10 structure
/// built here is narrow and fully documented inline; every OID is a
/// well-known constant, not derived.
///
/// No Secure Enclave (kSecAttrTokenIDSecureEnclave) in this first pass —
/// deliberately, so this still works on Simulator (SE key generation fails
/// outright there) during development. The key is still Keychain-resident
/// and non-exportable either way; SE would add hardware isolation on top,
/// not the exportability property itself, and can be layered in later once
/// this is verified working end to end on a real device.
///
/// Also exposes `mtlsRequest`: a real mTLS-authenticated HTTP request,
/// answering the server's client-certificate TLS challenge with the
/// SecIdentity Keychain forms automatically from this stored key + its
/// issued certificate. Used by GET /api/device-data/agent-status today, and
/// by POST /api/device-mtls/renew once that gets a Dart-side caller — see
/// ARCHITECTURE.md §2.6.
///
/// UNVERIFIED against a real device/Simulator build by this plugin's own
/// tooling — no local Xcode toolchain in this sandbox to compile or
/// exercise this against. Registration (generateCsr/storeCertificate) has
/// been confirmed end-to-end by the user on iOS Simulator against the live
/// Applivery fleet — see ARCHITECTURE.md §2.4. mtlsRequest itself has not
/// yet had the same live-device confirmation; before trusting it in
/// practice, confirm a real agent-status call succeeds against an enrolled
/// device on a workspace with mTLS enforcement enabled.
final class MtlsIdentityPlugin: NSObject, FlutterPlugin {
    private static let channelName = "es.applivery.soar/mtls_identity"
    private static let keyTag = "es.applivery.soar.mtls".data(using: .utf8)!
    // Distinguishes the issuing CA certificate (stored alongside the leaf so
    // mtlsRequest can present a full chain) from the leaf certificate itself
    // in kSecClassCertificate queries — the leaf needs no such label since
    // it's always found via kSecClassIdentity (paired automatically with the
    // matching private key), not looked up directly by this plugin.
    private static let caCertLabel = "es.applivery.soar.mtls.ca"

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = MtlsIdentityPlugin()
        let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "hasIdentity":
            result(hasIdentity())
        case "generateCsr":
            guard let args = call.arguments as? [String: Any],
                  let commonName = args["commonName"] as? String, !commonName.isEmpty else {
                result(FlutterError(code: "bad_args", message: "commonName is required", details: nil))
                return
            }
            do {
                result(try generateCsr(commonName: commonName))
            } catch {
                result(FlutterError(code: "mtls_identity_error", message: "\(error)", details: nil))
            }
        case "storeCertificate":
            guard let args = call.arguments as? [String: Any],
                  let certPem = args["certPem"] as? String, !certPem.isEmpty else {
                result(FlutterError(code: "bad_args", message: "certPem is required", details: nil))
                return
            }
            let caCertPem = args["caCertPem"] as? String
            do {
                try storeCertificate(certPem: certPem, caCertPem: caCertPem)
                result(true)
            } catch {
                result(FlutterError(code: "mtls_identity_error", message: "\(error)", details: nil))
            }
        case "clearIdentity":
            clearIdentity()
            result(true)
        case "mtlsRequest":
            guard let args = call.arguments as? [String: Any],
                  let urlString = args["url"] as? String,
                  let method = args["method"] as? String else {
                result(FlutterError(code: "bad_args", message: "url and method are required", details: nil))
                return
            }
            let headers = args["headers"] as? [String: String] ?? [:]
            let body = args["body"] as? String
            mtlsRequest(urlString: urlString, method: method, headers: headers, body: body) { response, error in
                if let error = error {
                    result(FlutterError(code: "mtls_request_error", message: "\(error)", details: nil))
                } else {
                    result(response)
                }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Keychain identity lifecycle

    private func hasIdentity() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrApplicationTag as String: Self.keyTag,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private func clearIdentity() {
        let keyQuery: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: Self.keyTag]
        SecItemDelete(keyQuery as CFDictionary)
        // No per-item tag on certificate entries the way private keys have
        // kSecAttrApplicationTag — but iOS keychains are per-app-sandboxed
        // by default (no keychain-sharing entitlement configured in this
        // project), so this app's keychain only ever holds the one
        // certificate storeCertificate adds; a class-wide delete here is
        // scoped to this app's own data, not reckless system-wide.
        let certQuery: [String: Any] = [kSecClass as String: kSecClassCertificate]
        SecItemDelete(certQuery as CFDictionary)
    }

    private func generatePrivateKey() throws -> SecKey {
        // Any previous pending key under this tag is deleted first — a
        // half-finished enrollment attempt's key is never reused, matching
        // the desktop agents' own generateMtlsKeyAndCsr (a fresh key per
        // attempt) and the Android side's identical behavior.
        let deleteQuery: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: Self.keyTag]
        SecItemDelete(deleteQuery as CFDictionary)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Self.keyTag,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw (error?.takeRetainedValue() as Error?) ?? NSError(domain: "MtlsIdentityPlugin", code: -1)
        }
        return privateKey
    }

    // MARK: - CSR building (RFC 2986), hand-rolled DER — see file doc comment

    private func generateCsr(commonName: String) throws -> String {
        let privateKey = try generatePrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw NSError(domain: "MtlsIdentityPlugin", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not derive public key."])
        }
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw (error?.takeRetainedValue() as Error?) ?? NSError(domain: "MtlsIdentityPlugin", code: -1)
        }
        // Uncompressed EC point (0x04 || X || Y) — exactly what
        // SubjectPublicKeyInfo's BIT STRING content should contain for an
        // id-ecPublicKey key, no further transformation needed.
        let rawPublicKeyBytes = [UInt8](publicKeyData)

        let certReqInfo = Self.derSequence(
            Self.derInteger(0) +
            Self.derSubjectName(commonName: commonName) +
            Self.derSubjectPublicKeyInfo(rawPublicKeyBytes: rawPublicKeyBytes) +
            Self.derContextConstructed(0, [])  // empty Attributes [0], no attributes requested
        )

        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            Data(certReqInfo) as CFData,
            &error
        ) as Data? else {
            throw (error?.takeRetainedValue() as Error?) ?? NSError(domain: "MtlsIdentityPlugin", code: -1)
        }
        // X9.62/ANSI ECDSA signature format IS already DER SEQUENCE{r, s} —
        // the same format X.509/PKCS10 expects, so signature bytes go
        // straight into the BIT STRING with no re-encoding.

        let signatureAlgorithm = Self.derSequence(Self.derOid(Self.oidEcdsaWithSha256))
        let certificationRequest = Self.derSequence(
            certReqInfo + signatureAlgorithm + Self.derBitString([UInt8](signature))
        )

        return Self.toPem(certificationRequest, label: "CERTIFICATE REQUEST")
    }

    // MARK: - Certificate storage

    /// [caCertPem], when present (POST /api/device-mtls/register's response
    /// includes it alongside certPem — see deviceMtls.service.ts), is stored
    /// as a separate, labeled certificate item so mtlsRequest's
    /// URLSessionDelegate can retrieve it and include it in the
    /// URLCredential's `certificates` array — completing the chain some
    /// server-side TLS stacks expect the client to present alongside its
    /// leaf cert, even when the issuing CA is otherwise already trusted.
    private func storeCertificate(certPem: String, caCertPem: String?) throws {
        let der = try Self.pemToDer(certPem)
        guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
            throw NSError(domain: "MtlsIdentityPlugin", code: -1, userInfo: [NSLocalizedDescriptionKey: "certPem did not parse as a valid X.509 certificate."])
        }
        // Adding the certificate to the same keychain as the private key is
        // all that's needed — Security framework automatically associates a
        // certificate with any private key already present whose public key
        // matches, forming a SecIdentity queryable via kSecClassIdentity. No
        // explicit "attach to this specific key" API exists or is needed.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw NSError(domain: "MtlsIdentityPlugin", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not store issued certificate (OSStatus \(status))."])
        }

        guard let caCertPem = caCertPem, !caCertPem.isEmpty else { return }
        let caDer = try Self.pemToDer(caCertPem)
        guard let caCertificate = SecCertificateCreateWithData(nil, Data(caDer) as CFData) else {
            throw NSError(domain: "MtlsIdentityPlugin", code: -1, userInfo: [NSLocalizedDescriptionKey: "caCertPem did not parse as a valid X.509 certificate."])
        }
        // Labeled (unlike the leaf) so loadCaCertificate() below can find
        // this one specifically — the leaf's public key matches our stored
        // private key and forms a SecIdentity; the CA cert's does not, so it
        // never gets confused for the leaf by that automatic pairing, but it
        // still needs its own retrievable identity here since kSecClass
        // certificate queries without a label would otherwise return
        // whichever certificate the Keychain happens to return first.
        let caAddQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: caCertificate,
            kSecAttrLabel as String: Self.caCertLabel,
        ]
        let caStatus = SecItemAdd(caAddQuery as CFDictionary, nil)
        guard caStatus == errSecSuccess || caStatus == errSecDuplicateItem else {
            throw NSError(domain: "MtlsIdentityPlugin", code: Int(caStatus), userInfo: [NSLocalizedDescriptionKey: "Could not store issuing CA certificate (OSStatus \(caStatus))."])
        }
    }

    // MARK: - mTLS-authenticated HTTP requests

    /// Performs an mTLS-authenticated HTTP request using the identity
    /// already formed in the Keychain by storeCertificate/generatePrivateKey
    /// to answer the server's client-certificate challenge (see the
    /// URLSessionDelegate conformance below) — server TLS certificate
    /// validation itself goes through URLSession's normal default handling
    /// (`.performDefaultHandling` for any non-client-cert challenge), since
    /// the SOAR backend's own server certificate is a regular
    /// publicly-trusted one with no special pinning need here.
    ///
    /// Builds a fresh, ephemeral URLSession per call rather than sharing one
    /// long-lived session — this method is called rarely (status refresh,
    /// eventually renewal), so the small per-call session setup cost isn't
    /// worth the complexity of session lifecycle management, and an
    /// ephemeral session guarantees no cross-call response caching hides a
    /// stale compliance status.
    private func mtlsRequest(
        urlString: String,
        method: String,
        headers: [String: String],
        body: String?,
        completion: @escaping ([String: Any]?, Error?) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            completion(nil, NSError(domain: "MtlsIdentityPlugin", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(urlString)"]))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body = body {
            request.httpBody = body.data(using: .utf8)
        }

        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(nil, error)
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyString = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            completion(["statusCode": statusCode, "body": bodyString], nil)
        }
        task.resume()
    }

    /// Looks up the SecIdentity formed by pairing the Keychain-resident
    /// private key (tagged Self.keyTag) with its matching leaf certificate —
    /// the same query shape hasIdentity() above already uses to confirm
    /// enrollment completed, reused here to actually retrieve the identity
    /// object URLCredential needs.
    private func loadIdentity() throws -> SecIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrApplicationTag as String: Self.keyTag,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let identity = item else {
            throw NSError(domain: "MtlsIdentityPlugin", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "No enrolled identity found (OSStatus \(status)) — enroll before calling mtlsRequest."])
        }
        // Safe force-cast: kSecClassIdentity + kSecReturnRef always yields a
        // SecIdentity on success, per Security framework's own contract.
        return (identity as! SecIdentity)
    }

    /// The issuing CA certificate stored by storeCertificate, if any —
    /// absent for identities enrolled before that field was captured, which
    /// is fine: URLCredential's `certificates` array is additive context for
    /// completing the chain, not a hard requirement for the leaf cert
    /// challenge response itself.
    private func loadCaCertificate() -> SecCertificate? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: Self.caCertLabel,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let certificate = item else { return nil }
        return (certificate as! SecCertificate)
    }

    // MARK: - DER/ASN.1 helpers — see file doc comment for why hand-rolled

    private static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var len = length
        while len > 0 {
            bytes.insert(UInt8(len & 0xFF), at: 0)
            len >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func derTLV(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        return [tag] + derLength(content.count) + content
    }

    private static func derSequence(_ content: [UInt8]) -> [UInt8] { derTLV(0x30, content) }
    private static func derSet(_ content: [UInt8]) -> [UInt8] { derTLV(0x31, content) }
    private static func derContextConstructed(_ tagNumber: UInt8, _ content: [UInt8]) -> [UInt8] { derTLV(0xA0 | tagNumber, content) }
    private static func derInteger(_ value: Int) -> [UInt8] { derTLV(0x02, [UInt8(value)]) } // only ever called with 0 (CSR version) here
    private static func derOid(_ bytes: [UInt8]) -> [UInt8] { derTLV(0x06, bytes) }
    private static func derUtf8String(_ s: String) -> [UInt8] { derTLV(0x0C, Array(s.utf8)) }
    private static func derBitString(_ bytes: [UInt8]) -> [UInt8] { derTLV(0x03, [0x00] + bytes) } // 0 unused bits — always byte-aligned here

    // Well-known DER-encoded OID bodies (RFC 5480 / RFC 3279) — constants,
    // not derived, so there's no OID-arc-encoding logic to get wrong here.
    private static let oidEcPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]      // 1.2.840.10045.2.1
    private static let oidPrime256v1: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07] // 1.2.840.10045.3.1.7 (secp256r1)
    private static let oidEcdsaWithSha256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02] // 1.2.840.10045.4.3.2
    private static let oidCommonName: [UInt8] = [0x55, 0x04, 0x03] // 2.5.4.3

    private static func derSubjectPublicKeyInfo(rawPublicKeyBytes: [UInt8]) -> [UInt8] {
        let algorithmIdentifier = derSequence(derOid(oidEcPublicKey) + derOid(oidPrime256v1))
        return derSequence(algorithmIdentifier + derBitString(rawPublicKeyBytes))
    }

    private static func derSubjectName(commonName: String) -> [UInt8] {
        let attributeTypeAndValue = derSequence(derOid(oidCommonName) + derUtf8String(commonName))
        let relativeDistinguishedName = derSet(attributeTypeAndValue)
        return derSequence(relativeDistinguishedName)
    }

    private static func toPem(_ der: [UInt8], label: String) -> String {
        let base64 = Data(der).base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
    }

    private static func pemToDer(_ pem: String) throws -> [UInt8] {
        let base64Body = pem
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: base64Body) else {
            throw NSError(domain: "MtlsIdentityPlugin", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not base64-decode PEM body."])
        }
        return [UInt8](data)
    }
}

// MARK: - URLSessionDelegate — answers the mTLS client-certificate challenge

/// Separate extension (rather than declaring conformance on the class
/// itself) purely for file organization — mtlsRequest above is the only
/// caller, via `URLSession(configuration:delegate:delegateQueue:)`.
extension MtlsIdentityPlugin: URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
            // Everything else (server trust included) — defer to URLSession's
            // normal handling, i.e. the system trust store for the SOAR
            // backend's own regular publicly-trusted TLS certificate. No
            // pinning here; see mtlsRequest's own doc comment.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        do {
            let identity = try loadIdentity()
            let caCertificate = loadCaCertificate()
            let credential = URLCredential(
                identity: identity,
                certificates: caCertificate.map { [$0] },
                persistence: .forSession
            )
            completionHandler(.useCredential, credential)
        } catch {
            // No enrolled identity (or a Keychain error reading it) — cancel
            // rather than silently proceeding without a client certificate,
            // which would let the server treat this as an unauthenticated
            // request instead of surfacing a clear "not enrolled" failure up
            // through mtlsRequest's completion handler.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
