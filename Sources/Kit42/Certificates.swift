import Foundation
import Security

/// Signing identity (certificate + private key) from the user's Keychain.
public struct SigningIdentity {
    public let identity: SecIdentity
    public let name: String
    public let email: String?

    init?(_ identity: SecIdentity) {
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { return nil }
        self.identity = identity
        name = SecCertificateCopySubjectSummary(cert) as String? ?? L("Unnamed")
        var emails: CFArray?
        SecCertificateCopyEmailAddresses(cert, &emails)
        email = (emails as? [String])?.first
    }

    public var displayName: String { email.map { "\(name) <\($0)>" } ?? name }
}

public enum CertificateStore {
    public static func identities() -> [SigningIdentity] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let array = result as? [SecIdentity] else { return [] }
        var seen = Set<String>()
        return array.compactMap(SigningIdentity.init).filter { seen.insert($0.displayName).inserted }
    }

    /// Imports a .p12/.pfx. With `toKeychain` the identity is also added to the login Keychain.
    public static func importPKCS12(_ data: Data, password: String, toKeychain: Bool) throws -> SigningIdentity {
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if !toKeychain, #available(macOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw error(status, L("Could not open the certificate file (wrong password?)")) }
        guard let dict = (items as? [[String: Any]])?.first,
              let ref = dict[kSecImportItemIdentity as String] else { throw error(errSecItemNotFound, L("The file contains no certificate with a private key")) }
        let identity = ref as! SecIdentity
        if toKeychain {
            let add = SecItemAdd([kSecValueRef as String: identity] as CFDictionary, nil)
            guard add == errSecSuccess || add == errSecDuplicateItem else { throw error(add, L("Could not add the certificate to the Keychain")) }
        }
        guard let signing = SigningIdentity(identity) else { throw error(errSecItemNotFound, L("The certificate cannot be read")) }
        return signing
    }

    /// Creates a self-signed signing certificate with the system `openssl` and adds it to the Keychain.
    public static func createSelfSigned(name: String, email: String, organization: String, years: Int = 5) throws -> SigningIdentity {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func clean(_ s: String) -> String { s.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: "=", with: " ") }
        var subject = "/CN=\(clean(name))"
        if !organization.isEmpty { subject += "/O=\(clean(organization))" }
        if !email.isEmpty { subject += "/emailAddress=\(clean(email))" }
        let password = UUID().uuidString

        try run(["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "\(years * 365)", "-nodes", "-utf8",
                 "-keyout", "key.pem", "-out", "cert.pem", "-subj", subject,
                 "-addext", "keyUsage=critical,digitalSignature,nonRepudiation"], in: dir)
        try run(["pkcs12", "-export", "-inkey", "key.pem", "-in", "cert.pem", "-out", "id.p12",
                 "-passout", "pass:\(password)", "-name", clean(name)], in: dir)
        let data = try Data(contentsOf: dir.appendingPathComponent("id.p12"))
        return try importPKCS12(data, password: password, toKeychain: true)
    }

    private static func run(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.currentDirectoryURL = dir
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "Suite42", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "openssl: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
    }

    static func error(_ status: OSStatus, _ text: String) -> NSError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: "\(text): \(detail)"])
    }
}
