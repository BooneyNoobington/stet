import CryptoKit
import Foundation
import Security

/// A service that confirms, with its signature, that a checksum existed at a point in time
/// (RFC 3161). Stet only ever sends the SHA-256 of what it stamps, never text.
public struct TimestampAuthority: Codable, Hashable, Identifiable {
    public var name: String
    public var url: String
    public var id: String { url }

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }

    /// Free services of two large certificate authorities; no account needed. Their certificates
    /// are in every common trust store, so anyone can check the stamps with standard tools.
    public static let defaults = [
        TimestampAuthority(name: "DigiCert", url: "http://timestamp.digicert.com"),
        TimestampAuthority(name: "Sectigo", url: "http://timestamp.sectigo.com"),
    ]
}

public enum TimestampError: Error, LocalizedError, Equatable {
    case unreachable(String, String)
    case refused(String, String)
    case invalid(String, String)
    case mismatch(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let name, let detail): "\(name) ist nicht erreichbar: \(detail)"
        case .refused(let name, let detail): "\(name) hat keinen Zeitstempel ausgestellt: \(detail)"
        case .invalid(let name, let detail): "Die Antwort von \(name) ist kein gültiger Zeitstempel: \(detail)"
        case .mismatch(let name): "Der Zeitstempel von \(name) gilt nicht für diese Prüfsumme."
        }
    }
}

/// A stamp as the authority returned it.
public struct TrustedTimestamp: Equatable {
    public let authority: String
    /// The complete response, DER encoded: what `openssl ts -verify -in` reads.
    public let response: Data
    public let time: Date
    public let digest: Data
}

/// What a stamp vouches for, after checking the authority's signature.
public struct TimestampVerification: Equatable {
    public let time: Date
    public let digest: Data
    public let serial: String
    public let policy: String
    public let nonce: [UInt8]?
    /// The name in the authority's certificate.
    public let signer: String
    /// True if the authority's certificate chains to a trusted root (as of the stamped time).
    public let trusted: Bool
    public let trustProblem: String?
    /// The chain macOS built for the authority's certificate, DER, its own first, root last.
    public let chain: [Data]
    /// The certificates inside the stamp (what `openssl ts -verify -untrusted` needs).
    public let embedded: [Data]
}

public enum RFC3161 {
    static let sha256OID = "2.16.840.1.101.3.4.2.1"
    static let tstInfoOID = "1.2.840.113549.1.9.16.1.4"

    /// A TimeStampReq for a SHA-256 digest, asking for the authority's certificate in the reply.
    public static func request(digest: Data, nonce: [UInt8]) -> Data {
        let imprint = DER.sequence([DER.sequence([DER.oid(sha256OID), DER.null]), DER.octetString(Array(digest))])
        return Data(DER.sequence([DER.integer(1), imprint, DER.integer(nonce), DER.boolean(true)]))
    }

    /// Status (0 = granted, 1 = granted with modifications), the service's explanation and the token.
    static func parseResponse(_ data: Data) throws -> (status: Int, text: String?, token: [UInt8]?) {
        let parts = try DER.parse(Array(data)).children()
        guard let statusInfo = parts.first, statusInfo.tag == 0x30 else { throw DER.Failure.unsupported }
        let statusParts = try statusInfo.children()
        guard let status = statusParts.first, status.tag == 0x02 else { throw DER.Failure.unsupported }
        var text: String?
        if statusParts.count > 1, statusParts[1].tag == 0x30 {
            text = try statusParts[1].children().map { String(decoding: $0.content, as: UTF8.self) }.joined(separator: " ")
        }
        return (DER.integerValue(status.content), text, parts.count > 1 ? parts[1].encoded : nil)
    }

    struct TSTInfo {
        let policy: String
        let hashAlgorithm: String
        let digest: Data
        let serial: String
        let time: Date
        let nonce: [UInt8]?
    }

    static func parseTSTInfo(_ bytes: [UInt8]) throws -> TSTInfo {
        let fields = try DER.parse(bytes).children()
        guard fields.count >= 5, fields[1].tag == 0x06, fields[2].tag == 0x30, fields[3].tag == 0x02, fields[4].tag == 0x18,
              let time = DER.generalizedTime(fields[4].content)
        else { throw DER.Failure.unsupported }
        let imprint = try fields[2].children()
        guard imprint.count == 2, let algorithm = try imprint[0].children().first, imprint[1].tag == 0x04 else {
            throw DER.Failure.unsupported
        }
        let nonce = fields.dropFirst(5).first { $0.tag == 0x02 }.map { Array($0.content.drop { $0 == 0 }) }
        return TSTInfo(
            policy: DER.oidString(fields[1].content),
            hashAlgorithm: DER.oidString(algorithm.content),
            digest: Data(imprint[1].content),
            serial: fields[3].content.map { String(format: "%02x", $0) }.joined(),
            time: time,
            nonce: nonce
        )
    }

    /// Checks a response: the authority's signature over the stamp, its certificate (as of the
    /// stamped time; `anchors` replaces the system's roots, for tests) and what it stamped.
    public static func verify(_ response: Data, anchors: [SecCertificate]? = nil) throws -> TimestampVerification {
        let parsed = try parseResponse(response)
        guard parsed.status <= 1, let token = parsed.token else {
            throw TimestampError.refused("Der Dienst", parsed.text ?? "Status \(parsed.status)")
        }
        return try verifyToken(token, anchors: anchors)
    }

    static func verifyToken(_ token: [UInt8], anchors: [SecCertificate]?) throws -> TimestampVerification {
        func decoder(detached: Data?) -> CMSDecoder? {
            var decoder: CMSDecoder?
            guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
            if let detached, CMSDecoderSetDetachedContent(decoder, detached as CFData) != errSecSuccess { return nil }
            let updated = token.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, token.count) }
            guard updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
            return decoder
        }
        let invalid = TimestampError.invalid("Der Dienst", "kein CMS-Umschlag")
        guard let envelope = decoder(detached: nil) else { throw invalid }
        var contentType: CFData?
        CMSDecoderCopyEncapsulatedContentType(envelope, &contentType)
        guard let contentType = contentType as Data?, DER.oidString(Array(contentType)) == tstInfoOID else {
            throw TimestampError.invalid("Der Dienst", "kein Zeitstempel-Inhalt")
        }
        var contentRef: CFData?
        CMSDecoderCopyContent(envelope, &contentRef)
        guard let content = contentRef as Data? else { throw invalid }

        // macOS reports "needs detached content" for this content type; handing it the very
        // bytes from inside the envelope makes it check the signature over them.
        guard let checked = decoder(detached: content) else { throw invalid }
        var signers = 0
        CMSDecoderGetNumSigners(checked, &signers)
        guard signers == 1 else { throw TimestampError.invalid("Der Dienst", "\(signers) Unterschriften") }
        let policy = SecPolicyCreateWithProperties(kSecPolicyAppleTimeStamping, nil) ?? SecPolicyCreateBasicX509()
        var status = CMSSignerStatus.unsigned
        var trustRef: SecTrust?
        var certificateResult: OSStatus = 0
        CMSDecoderCopySignerStatus(checked, 0, policy, false, &status, &trustRef, &certificateResult)
        guard status == .valid else {
            throw TimestampError.invalid("Der Dienst", status == .invalidSignature ? "die Unterschrift passt nicht" : "Unterschrift nicht prüfbar (\(status.rawValue))")
        }
        let info = try parseTSTInfo(Array(content))
        guard info.hashAlgorithm == sha256OID else { throw TimestampError.invalid("Der Dienst", "kein SHA-256") }

        var allCertificates: CFArray?
        CMSDecoderCopyAllCerts(checked, &allCertificates)
        let embedded = ((allCertificates as? [SecCertificate]) ?? []).map { SecCertificateCopyData($0) as Data }

        var signerCertificate: SecCertificate?
        CMSDecoderCopySignerCert(checked, 0, &signerCertificate)
        let signer = signerCertificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "?"

        var trusted = false
        var problem: String?
        var chain: [Data] = []
        if let trust = trustRef {
            SecTrustSetVerifyDate(trust, info.time as CFDate)
            SecTrustSetNetworkFetchAllowed(trust, false)
            if let anchors { SecTrustSetAnchorCertificates(trust, anchors as CFArray) }
            var error: CFError?
            trusted = SecTrustEvaluateWithError(trust, &error)
            problem = error.map { CFErrorCopyDescription($0) as String }
            let certificates = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
            chain = certificates.map { SecCertificateCopyData($0) as Data }
        }
        if chain.isEmpty, let signerCertificate { chain = [SecCertificateCopyData(signerCertificate) as Data] }
        return TimestampVerification(
            time: info.time, digest: info.digest, serial: info.serial, policy: info.policy, nonce: info.nonce,
            signer: signer, trusted: trusted, trustProblem: trusted ? nil : problem, chain: chain, embedded: embedded
        )
    }

    /// Certificates as PEM, e.g. for `openssl … -CAfile`.
    public static func pem(_ certificates: [Data]) -> String {
        certificates.map { der in
            let lines = der.base64EncodedString().chunked(64)
            return "-----BEGIN CERTIFICATE-----\n" + lines.joined(separator: "\n") + "\n-----END CERTIFICATE-----\n"
        }.joined()
    }
}

/// Fetches stamps. The transport is replaceable so tests can use a local authority.
public struct TimestampClient {
    public typealias Transport = (URL, Data) async throws -> Data
    public var transport: Transport
    /// Replaces the system's trusted roots when checking replies (tests only).
    public var anchors: [SecCertificate]?

    public init(transport: @escaping Transport = TimestampClient.http, anchors: [SecCertificate]? = nil) {
        self.transport = transport
        self.anchors = anchors
    }

    public static func http(_ url: URL, _ body: Data) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/timestamp-query", forHTTPHeaderField: "Content-Type")
        request.setValue("application/timestamp-reply", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        return data
    }

    /// Asks `authority` to stamp a SHA-256 digest and checks the reply before returning it.
    public func stamp(_ digest: Data, at authority: TimestampAuthority) async throws -> TrustedTimestamp {
        guard let url = URL(string: authority.url), url.scheme == "http" || url.scheme == "https" else {
            throw TimestampError.unreachable(authority.name, "Die Adresse „\(authority.url)“ ist ungültig.")
        }
        var nonce = (0..<8).map { _ in UInt8.random(in: 0...255) }
        nonce[0] = (nonce[0] & 0x7f) | 0x01
        let response: Data
        do {
            response = try await transport(url, RFC3161.request(digest: digest, nonce: nonce))
        } catch {
            throw TimestampError.unreachable(authority.name, error.localizedDescription)
        }
        let parsed: (status: Int, text: String?, token: [UInt8]?)
        do {
            parsed = try RFC3161.parseResponse(response)
        } catch {
            throw TimestampError.invalid(authority.name, "unlesbare Antwort")
        }
        guard parsed.status <= 1, let token = parsed.token else {
            throw TimestampError.refused(authority.name, parsed.text ?? "Status \(parsed.status)")
        }
        let verification: TimestampVerification
        do {
            verification = try RFC3161.verifyToken(token, anchors: anchors)
        } catch TimestampError.invalid(_, let detail) {
            throw TimestampError.invalid(authority.name, detail)
        }
        guard verification.digest == digest, verification.nonce == Array(nonce.drop { $0 == 0 }) else {
            throw TimestampError.mismatch(authority.name)
        }
        return TrustedTimestamp(authority: authority.name, response: response, time: verification.time, digest: digest)
    }
}

extension Data {
    var sha256: Data { Data(SHA256.hash(data: self)) }
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

extension String {
    func chunked(_ size: Int) -> [String] {
        var result: [String] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[index..<next]))
            index = next
        }
        return result
    }
}

// MARK: - A local authority for tests

/// A timestamp authority on this Mac with a throwaway CA, for tests and the self-test: replies
/// come from `openssl ts -reply`, nothing leaves the machine.
public final class LocalTestTSA {
    public let folder: URL
    public let caCertificate: SecCertificate
    public var caPEM: URL { folder.appendingPathComponent("ca.pem") }

    public init(in folder: URL) throws {
        self.folder = folder
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = """
        [req]
        distinguished_name = dn
        prompt = no
        [dn]
        CN = Stet Test CA
        [v3_ca]
        basicConstraints = critical,CA:true
        keyUsage = critical,keyCertSign,cRLSign
        subjectKeyIdentifier = hash
        [v3_tsa]
        basicConstraints = critical,CA:false
        keyUsage = critical,digitalSignature
        extendedKeyUsage = critical,timeStamping
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid
        [tsa]
        default_tsa = tsa_config
        [tsa_config]
        dir = \(folder.path)
        serial = $dir/serial
        signer_cert = $dir/tsa.pem
        certs = $dir/tsa.pem
        signer_key = $dir/tsa.key
        default_policy = 1.2.3.4.1
        digests = sha256
        accuracy = secs:1
        ordering = no
        tsa_name = yes
        ess_cert_id_chain = no

        """
        try Data(config.utf8).write(to: folder.appendingPathComponent("openssl.cnf"))
        try Data("01\n".utf8).write(to: folder.appendingPathComponent("serial"))
        let steps: [[String]] = [
            ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "3650",
             "-config", "openssl.cnf", "-extensions", "v3_ca"],
            ["req", "-newkey", "rsa:2048", "-nodes", "-keyout", "tsa.key", "-out", "tsa.csr", "-subj", "/CN=Stet Test TSA"],
            ["x509", "-req", "-in", "tsa.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "tsa.pem",
             "-days", "3650", "-sha256", "-extfile", "openssl.cnf", "-extensions", "v3_tsa"],
            ["x509", "-in", "ca.pem", "-outform", "DER", "-out", "ca.der"],
        ]
        for step in steps {
            let result = try Tools.run(Tools.openssl, step, in: folder)
            guard result.status == 0 else { throw TimestampError.invalid("Test-Dienst", result.errors) }
        }
        guard let der = fm.contents(atPath: folder.appendingPathComponent("ca.der").path),
              let certificate = SecCertificateCreateWithData(nil, der as CFData)
        else { throw TimestampError.invalid("Test-Dienst", "CA fehlt") }
        caCertificate = certificate
    }

    /// Answers a TimeStampReq.
    public func respond(_ query: Data) throws -> Data {
        let id = UUID().uuidString
        let queryURL = folder.appendingPathComponent("\(id).tsq"), replyURL = folder.appendingPathComponent("\(id).tsr")
        defer {
            try? FileManager.default.removeItem(at: queryURL)
            try? FileManager.default.removeItem(at: replyURL)
        }
        try query.write(to: queryURL)
        let result = try Tools.run(Tools.openssl, ["ts", "-reply", "-config", "openssl.cnf", "-queryfile", queryURL.path, "-out", replyURL.path], in: folder)
        guard result.status == 0, let reply = FileManager.default.contents(atPath: replyURL.path) else {
            throw TimestampError.unreachable("Test-Dienst", result.errors)
        }
        return reply
    }

    private let lock = NSLock()

    /// A client that talks to this authority (one request at a time: openssl keeps a serial file).
    public var client: TimestampClient {
        TimestampClient(transport: { [self] _, body in try respondSerially(body) }, anchors: [caCertificate])
    }

    private func respondSerially(_ query: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try respond(query)
    }
}
