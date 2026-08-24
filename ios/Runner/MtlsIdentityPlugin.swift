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
/// Renewal (POST /api/device-mtls/renew, which needs an mTLS-authenticated
/// HTTP client bound to this key) is NOT implemented yet — see
/// ARCHITECTURE.md's identity section. This plugin currently only covers
/// first-time registration.
///
/// UNVERIFIED against a real device/Simulator build — no local Xcode
/// toolchain in this sandbox to compile or exercise this against. Before
/// trusting this in practice: confirm generateCsr's output parses as a
/// valid CSR (`openssl req -in csr.pem -noout -text`), and specifically
/// confirm the hand-rolled DER decodes correctly — a malformed
/// SubjectPublicKeyInfo or signature encoding would make the backend reject
/// every registration attempt with no useful error from this side.
final class MtlsIdentityPlugin: NSObject, FlutterPlugin {
    private static let channelName = "es.applivery.soar/mtls_identity"
    private static let keyTag = "es.applivery.soar.mtls".data(using: .utf8)!

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
            do {
                try storeCertificate(certPem: certPem)
                result(true)
            } catch {
                result(FlutterError(code: "mtls_identity_error", message: "\(error)", details: nil))
            }
        case "clearIdentity":
            clearIdentity()
            result(true)
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

    private func storeCertificate(certPem: String) throws {
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
