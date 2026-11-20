import Foundation
import Security
import XCTest
@testable import StetCore

/// Signatures, timestamps and proofs. Everything runs on this Mac: throwaway keys, a throwaway
/// SSH agent and a local timestamp authority (openssl). Real services only with STET_LIVE_TSA=1.
final class ProofTests: TempDirTestCase {
    private var savedFolder: URL!
    private var failures: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedFolder = SSHKey.folder
        SSHKey.folder = temp.appendingPathComponent("Keys")
        failures = []
        Signing.onFailure = { [weak self] reason in self?.failures.append(reason) }
    }

    override func tearDownWithError() throws {
        Signing.current = nil
        Signing.onFailure = nil
        SSHKey.folder = savedFolder
        try super.tearDownWithError()
    }

    private func makeBook(_ name: String = "Buch") async throws -> Book {
        try await Book.create(at: temp.appendingPathComponent("\(name).stet"), title: name, author: "Test")
    }

    private func edit(_ book: Book, _ text: String) throws {
        var scene = try book.readScene(book.manifest.sceneIDs[0])
        scene.body = text
        try book.writeScene(scene)
    }

    private func tsa() throws -> LocalTestTSA { try LocalTestTSA(in: temp.appendingPathComponent("TSA")) }

    private let authorities = [TimestampAuthority(name: "Dienst A", url: "http://a.test"), TimestampAuthority(name: "Dienst B", url: "http://b.test")]

    // MARK: DER and RFC 3161

    func testDEREncodesOIDsAndIntegers() throws {
        XCTAssertEqual(DER.oid("2.16.840.1.101.3.4.2.1"), [0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01])
        XCTAssertEqual(DER.oidString(Array(DER.oid("1.2.840.113549.1.9.16.1.4").dropFirst(2))), "1.2.840.113549.1.9.16.1.4")
        XCTAssertEqual(DER.integer(1), [0x02, 0x01, 0x01])
        XCTAssertEqual(DER.integer([0x80]), [0x02, 0x02, 0x00, 0x80])
        let long = DER.octetString([UInt8](repeating: 7, count: 300))
        XCTAssertEqual(Array(long.prefix(4)), [0x04, 0x82, 0x01, 0x2c])
        XCTAssertEqual(try DER.parse(long).content.count, 300)
    }

    func testRequestIsReadableByOpenSSL() throws {
        let digest = Data("Probe".utf8).sha256
        let query = temp.appendingPathComponent("q.tsq")
        try RFC3161.request(digest: digest, nonce: [0x12, 0x34]).write(to: query)
        let text = try Tools.run(Tools.openssl, ["ts", "-query", "-in", query.path, "-text"]).text
        XCTAssertTrue(text.contains("sha256"))
        XCTAssertTrue(text.lowercased().contains("0x1234"))
        XCTAssertTrue(text.contains("Certificate required: yes"))
    }

    func testLocalAuthorityStampsAndVerifies() async throws {
        let tsa = try tsa()
        let digest = Data("Ein Satz.".utf8).sha256
        let stamp = try await tsa.client.stamp(digest, at: authorities[0])
        XCTAssertEqual(stamp.digest, digest)
        XCTAssertLessThan(abs(stamp.time.timeIntervalSinceNow), 120)

        let trusted = try RFC3161.verify(stamp.response, anchors: [tsa.caCertificate])
        XCTAssertTrue(trusted.trusted)
        XCTAssertEqual(trusted.digest, digest)
        XCTAssertEqual(trusted.signer, "Stet Test TSA")
        XCTAssertGreaterThanOrEqual(trusted.chain.count, 2)

        // Without the test CA nothing vouches for the service.
        XCTAssertFalse(try RFC3161.verify(stamp.response).trusted)

        // Tampering with the stamped checksum breaks the service's signature.
        var bytes = [UInt8](stamp.response)
        let range = bytes.indices.dropLast(digest.count).first { Array(bytes[$0..<($0 + digest.count)]) == Array(digest) }
        let at = try XCTUnwrap(range)
        bytes[at] ^= 0xff
        XCTAssertThrowsError(try RFC3161.verify(Data(bytes), anchors: [tsa.caCertificate]))

        // openssl agrees.
        let reply = temp.appendingPathComponent("r.tsr")
        try stamp.response.write(to: reply)
        let check = try Tools.run(Tools.openssl, ["ts", "-verify", "-digest", digest.hex, "-in", reply.path, "-CAfile", tsa.caPEM.path])
        XCTAssertTrue((check.text + check.errors).contains("Verification: OK"), check.errors)
    }

    func testClientRejectsAStampForSomethingElse() async throws {
        let tsa = try tsa()
        let other = try await tsa.client.stamp(Data("anderes".utf8).sha256, at: authorities[0])
        let liar = TimestampClient(transport: { _, _ in other.response }, anchors: [tsa.caCertificate])
        do {
            _ = try await liar.stamp(Data("meins".utf8).sha256, at: authorities[0])
            XCTFail("accepted a stamp for another checksum")
        } catch let error as TimestampError {
            XCTAssertEqual(error, .mismatch("Dienst A"))
        }
        let down = TimestampClient(transport: { _, _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await down.stamp(Data("x".utf8).sha256, at: authorities[1])
            XCTFail("no error while offline")
        } catch let error as TimestampError {
            guard case .unreachable("Dienst B", _) = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Signing

    func testVersionsMilestonesAndExportTagsAreSignedSnapshotsAreNot() async throws {
        Signing.current = try Signing.makeStetKey()
        let book = try await makeBook()
        let first = try await book.signatures(of: ["HEAD"])["HEAD"]
        XCTAssertEqual(first?.state, .good, "the first version is signed")
        XCTAssertEqual(first?.key, Signing.current?.fingerprint)

        try edit(book, "Neuer Text.\n")
        let snapshot = try await book.snapshot(device: "test")
        let snapshotState = try await book.signatures(of: [XCTUnwrap(snapshot)])[XCTUnwrap(snapshot)]?.state
        XCTAssertEqual(snapshotState, .unsigned, "snapshots stay unsigned (no Touch ID every ten minutes)")

        try await book.saveVersion()
        let saved = await book.signatures(of: ["HEAD"])["HEAD"]?.state
        XCTAssertEqual(saved, .good)

        let milestone = try await book.setMilestone(name: "Erste Fassung")
        let tag = try XCTUnwrap(milestone?.tag)
        let allowed = temp.appendingPathComponent("allowed")
        try Data("* \(try XCTUnwrap(Signing.current?.sshPublicKey))\n".utf8).write(to: allowed)
        let verified = try await book.git.run(Git.verificationArguments(allowedSigners: allowed) + ["tag", "-v", tag], allowedStatus: [0, 1])
        XCTAssertEqual(verified.status, 0, verified.stderr)
        XCTAssertTrue(failures.isEmpty)
    }

    func testAnotherMacsKeyIsRecognisedThroughTheBook() async throws {
        let macA = try Signing.makeStetKey()
        Signing.current = macA
        let book = try await makeBook()
        XCTAssertTrue(try book.registerSigner(macA))
        XCTAssertFalse(try book.registerSigner(macA), "registered once")
        let result = try await book.saveVersion()
        XCTAssertTrue(result?.subject.contains("Signatur-Schlüssel") == true)

        // Mac B: a different key; A's versions are still recognised through signers/.
        let keyB = try SSHKey.create(label: "Signatur B")
        Signing.current = SigningSetup(method: .stetKey(path: keyB.privateKeyURL.path), label: "B", fingerprint: keyB.fingerprint)
        let fromA = await book.signatures(of: ["HEAD"])["HEAD"]?.state
        XCTAssertEqual(fromA, .good)

        // Without signers/, A's signature is valid but its key unknown.
        try FileManager.default.removeItem(at: book.url.appendingPathComponent(Book.signersFolder))
        let unknown = await book.signatures(of: ["HEAD"])["HEAD"]?.state
        XCTAssertEqual(unknown, .unknownKey)
    }

    func testAMissingKeyNeverCostsAVersion() async throws {
        Signing.current = SigningSetup(method: .stetKey(path: temp.appendingPathComponent("gibt-es-nicht").path), label: "weg", fingerprint: "SHA256:x")
        let book = try await makeBook()
        try edit(book, "Trotzdem gesichert.\n")
        let result = try await book.saveVersion()
        XCTAssertNotNil(result)
        let state = await book.signatures(of: ["HEAD"])["HEAD"]?.state
        XCTAssertEqual(state, .unsigned)
        XCTAssertFalse(failures.isEmpty, "the app hears that the version is unsigned")
        let changed = try await book.git.changedPaths()
        XCTAssertTrue(changed.isEmpty)
    }

    func testAgentKeysSign() async throws {
        let short = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sa-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: short, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: short) }
        let socket = short.appendingPathComponent("s").path
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", socket]
        agent.standardOutput = FileHandle.nullDevice
        agent.standardError = FileHandle.nullDevice
        try agent.run()
        defer { agent.terminate() }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socket) { try await Task.sleep(for: .milliseconds(50)) }

        let key = try SSHKey.create(label: "Agent")
        XCTAssertEqual(try Tools.run(Tools.sshAdd, ["-q", key.privateKeyURL.path], environment: ["SSH_AUTH_SOCK": socket]).status, 0)
        let keys = Signing.agentKeys(socket: socket)
        XCTAssertEqual(keys.map(\.fingerprint), [key.fingerprint])

        let setup = SigningSetup(method: .sshAgent(socket: socket, publicKey: try XCTUnwrap(keys.first?.publicKey)), label: "Agent", fingerprint: key.fingerprint)
        let probe = try await Signing.probe(setup)
        XCTAssertEqual(probe.state, .good)

        Signing.current = setup
        let book = try await makeBook()
        let state = await book.signatures(of: ["HEAD"])["HEAD"]?.state
        XCTAssertEqual(state, .good)

        // Signing a file for a proof works through the agent as well.
        let file = temp.appendingPathComponent("Beleg.txt")
        try Data("Beleg\n".utf8).write(to: file)
        let signature = try await Signing.signDetached(file, with: setup)
        XCTAssertEqual(signature.files.map(\.name), ["Beleg.txt.sig", "Schlüssel.pub", "Schlüssel.allowed_signers"])
    }

    func testProbeReportsAMissingKey() async throws {
        let setup = SigningSetup(method: .stetKey(path: temp.appendingPathComponent("fehlt").path), label: "x", fingerprint: "x")
        do {
            _ = try await Signing.probe(setup)
            XCTFail("probe succeeded without a key")
        } catch let error as Signing.ProbeError {
            XCTAssertTrue(error.localizedDescription.contains("nicht gefunden"), error.localizedDescription)
        }
    }

    func testParsesSmimesignAndGPGListings() {
        let smime = """
               ID: 0a1b2c3d4e5f60718293a4b5c6d7e8f901234567
              S/N: 1234
        Algorithm: SHA256-RSA
         Validity: 2025-01-01 00:00:00 +0000 UTC - 2027-01-01 00:00:00 +0000 UTC
           Issuer: CN=Beispiel CA,O=Beispiel
          Subject: CN=Erika Mustermann
           Emails: erika@example.com

               ID: ffffffffffffffffffffffffffffffffffffffff
              S/N: 99
        Algorithm: SHA256-RSA
         Validity: 2020-01-01 00:00:00 +0000 UTC - 2021-01-01 00:00:00 +0000 UTC
           Issuer: CN=Alt CA
          Subject: CN=Erika Alt
           Emails: alt@example.com, zweit@example.com
        """
        let certificates = Signing.parseSmimesignList(smime)
        XCTAssertEqual(certificates.map(\.subject), ["Erika Mustermann", "Erika Alt"])
        XCTAssertEqual(certificates[0].issuer, "Beispiel CA")
        XCTAssertEqual(certificates[0].emails, ["erika@example.com"])
        XCTAssertFalse(certificates[0].isExpired)
        XCTAssertTrue(certificates[1].isExpired)
        XCTAssertEqual(certificates[1].emails.count, 2)

        let gpg = """
        sec:u:255:22:AAAABBBBCCCCDDDD:1700000000:1900000000::u:::scESC:::+:::ed25519:::0:
        fpr:::::::::0123456789ABCDEF0123AAAABBBBCCCCDDDD:
        grp:::::::::XYZ:
        uid:u::::1700000000::HASH::Erika Mustermann <erika@example.com>::::::::::0:
        ssb:u:255:18:EEEEFFFF00001111:1700000000::::::e:::+:::cv25519::
        fpr:::::::::9999999999999999999999EEEEFFFF00001111:
        sec:e:255:22:1111222233334444:1500000000:1600000000::u:::scESC:::+:::ed25519:::0:
        fpr:::::::::00001111222233334444:
        uid:e::::1500000000::HASH::Abgelaufen <alt@example.com>::::::::::0:
        sec:u:255:22:5555666677778888:1700000000:::u:::eE:::+:::cv25519:::0:
        fpr:::::::::55556666777788885555666677778888:
        uid:u::::1700000000::HASH::Nur Verschlüsseln::::::::::0:
        """
        let keys = Signing.parseGPGColons(gpg)
        XCTAssertEqual(keys.map(\.fingerprint), ["0123456789ABCDEF0123AAAABBBBCCCCDDDD"])
        XCTAssertEqual(keys.first?.userID, "Erika Mustermann <erika@example.com>")
    }

    func testOnlySigningOptionsAreStripped() {
        let setup = SigningSetup(method: .stetKey(path: "/k"), label: "k", fingerprint: "f", name: "Erika", email: "e@x")
        let args = ["-c", "user.name=Stet"] + setup.gitArguments + ["commit", "-m", "x"]
        let plain = Signing.unsigned(args)
        XCTAssertFalse(plain.contains(Signing.marker))
        XCTAssertFalse(plain.contains { $0.hasPrefix("user.signingkey") || $0.hasPrefix("gpg.") })
        XCTAssertTrue(plain.contains("user.email=e@x"))
        XCTAssertEqual(Array(plain.suffix(3)), ["commit", "-m", "x"])
    }

    // MARK: Receipts, stamps, proofs

    func testReceiptListsEveryFileAndIsStable() async throws {
        let book = try await makeBook()
        let receipt = try await book.receipt(for: "HEAD")
        let again = try await book.receipt(for: "HEAD")
        XCTAssertEqual(receipt, again)
        XCTAssertTrue(receipt.text.hasPrefix("Stet-Beleg 1\nVersion \(receipt.commit)\n\n"))
        XCTAssertTrue(receipt.paths.contains("manuscript.yaml"))
        XCTAssertTrue(receipt.paths.contains(Book.scenePath(book.manifest.sceneIDs[0])))
        let manifest = try Data(contentsOf: book.url.appendingPathComponent("manuscript.yaml")).sha256.hex
        XCTAssertTrue(receipt.text.contains("\(manifest)  manuscript.yaml"))

        try edit(book, "Anders.\n")
        try await book.saveVersion()
        let next = try await book.receipt(for: "HEAD")
        XCTAssertNotEqual(next.digest, receipt.digest)
    }

    func testQueueSurvivesBeingOfflineAndStampsOncePerDay() async throws {
        let tsa = try tsa()
        let book = try await makeBook()
        let morning = Date()
        let queued = try await book.queueVersionStamp(daily: true, now: morning)
        XCTAssertTrue(queued)
        let again = try await book.queueVersionStamp(daily: true, now: morning.addingTimeInterval(60))
        XCTAssertFalse(again, "one daily stamp")

        let offline = TimestampClient(transport: { _, _ in throw URLError(.notConnectedToInternet) })
        let failed = await book.processStamps(authorities: authorities, client: offline)
        XCTAssertEqual(failed.stamped, 0)
        XCTAssertEqual(failed.pending, 1)
        XCTAssertFalse(failed.problems.isEmpty)

        let run = await book.processStamps(authorities: authorities, client: tsa.client)
        XCTAssertEqual(run.stamped, 2)
        XCTAssertEqual(run.pending, 0)
        let headCommit = await book.git.headCommit()
        let head = try XCTUnwrap(headCommit)
        let stamps = await book.stamps()[head] ?? []
        XCTAssertEqual(Set(stamps.map(\.authority)), ["Dienst A", "Dienst B"])
        let receipt = try await book.receipt(for: head)
        XCTAssertTrue(stamps.allSatisfy { $0.digest == receipt.digest && $0.verify(anchors: [tsa.caCertificate])?.trusted == true })

        let tomorrow = try await book.queueVersionStamp(daily: true, now: morning.addingTimeInterval(86_400))
        XCTAssertTrue(tomorrow)
    }

    func testOneServiceDownStillStampsWithTheOther() async throws {
        let tsa = try tsa()
        let book = try await makeBook()
        try await book.queueVersionStamp()
        let half = TimestampClient(transport: { url, body in
            if url.host == "b.test" { throw URLError(.timedOut) }
            return try await tsa.client.transport(url, body)
        }, anchors: [tsa.caCertificate])
        let run = await book.processStamps(authorities: authorities, client: half)
        XCTAssertEqual(run.stamped, 1)
        XCTAssertEqual(run.pending, 1, "B is asked again next time")
        let rest = await book.processStamps(authorities: authorities, client: tsa.client)
        XCTAssertEqual(rest.stamped, 1)
        XCTAssertEqual(rest.pending, 0)
        let headCommit = await book.git.headCommit()
        let head = try XCTUnwrap(headCommit)
        let count = await book.stamps()[head]?.count
        XCTAssertEqual(count, 2)
    }

    func testVersionProofCanBeCheckedWithStandardTools() async throws {
        let tsa = try tsa()
        Signing.current = try Signing.makeStetKey()
        let book = try await makeBook()
        try edit(book, "Der erste Satz.\n\nUnd ein zweiter.\n")
        try await book.saveVersion()
        try await book.queueVersionStamp()
        _ = await book.processStamps(authorities: authorities, client: tsa.client)
        let headCommit = await book.git.headCommit()
        let head = try XCTUnwrap(headCommit)
        let stamps = await book.stamps()[head] ?? []
        let signature = await book.signatures(of: [head])[head]

        let folder = temp.appendingPathComponent("Nachweis")
        _ = try await Proof.writeVersion(head, of: book, stamps: stamps, signing: Signing.current, versionSignature: signature,
                                         to: folder, anchors: [tsa.caCertificate])
        let fm = FileManager.default
        for name in ["LIESMICH.txt", "Beleg.txt", "Beleg.txt.sig", "Schlüssel.allowed_signers", "Zeitstempel – Dienst A.tsr",
                     "Zeitstempel – Dienst B.tsr", "Zertifikate – Dienst A.pem", "Buch/manuscript.yaml"] {
            XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent(name).path), name)
        }

        // 1. The files match the receipt.
        let sums = try Tools.run(URL(fileURLWithPath: "/usr/bin/shasum"), ["-a", "256", "-c", "../Beleg.txt"], in: folder.appendingPathComponent("Buch"))
        XCTAssertEqual(sums.status, 0, sums.errors)
        XCTAssertTrue(sums.text.contains("manuscript.yaml: OK"))
        // 2. The stamps (with the test CA in place of the system's roots).
        for name in ["Dienst A", "Dienst B"] {
            let check = try Tools.run(Tools.openssl, ["ts", "-verify", "-data", "Beleg.txt", "-in", "Zeitstempel – \(name).tsr",
                                                      "-CAfile", tsa.caPEM.path, "-untrusted", "Zertifikate – \(name).pem"], in: folder)
            XCTAssertTrue((check.text + check.errors).contains("Verification: OK"), check.errors)
        }
        // 3. The signature.
        let verify = try Tools.run(Tools.sshKeygen, ["-Y", "verify", "-f", "Schlüssel.allowed_signers", "-I", "autor", "-n", "stet-nachweis",
                                                     "-s", "Beleg.txt.sig"], input: try Data(contentsOf: folder.appendingPathComponent("Beleg.txt")), in: folder)
        XCTAssertEqual(verify.status, 0, verify.errors)

        let readme = try read("LIESMICH.txt", in: folder)
        XCTAssertTrue(readme.contains("Dienst A: "))
        XCTAssertTrue(readme.contains("shasum -a 256 -c ../Beleg.txt"))
        XCTAssertTrue(readme.contains("ssh-keygen -Y verify"))
        XCTAssertTrue(readme.contains(head))
        XCTAssertTrue(readme.contains("Wurzelzertifikat: „Stet Test CA“"))

        // Changing a file is caught.
        try Data("verändert".utf8).write(to: folder.appendingPathComponent("Buch/manuscript.yaml"))
        let tampered = try Tools.run(URL(fileURLWithPath: "/usr/bin/shasum"), ["-a", "256", "-c", "../Beleg.txt"], in: folder.appendingPathComponent("Buch"))
        XCTAssertNotEqual(tampered.status, 0)
    }

    func testExportedFileIsStampedAndRecognised() async throws {
        let tsa = try tsa()
        let book = try await makeBook()
        let file = temp.appendingPathComponent("Roman.pdf")
        try Data("%PDF-Probe".utf8).write(to: file)
        try await book.queueFileStamp(file)
        _ = await book.processStamps(authorities: authorities, client: tsa.client)
        let found = try await book.stamps(forFile: file)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found.first?.kind, .file)
        XCTAssertEqual(found.first?.fileName, "Roman.pdf")

        let other = temp.appendingPathComponent("Anders.pdf")
        try Data("%PDF-Anders".utf8).write(to: other)
        let none = try await book.stamps(forFile: other)
        XCTAssertTrue(none.isEmpty)

        let folder = temp.appendingPathComponent("Nachweis Datei")
        _ = try await Proof.writeFile(file, of: book, stamps: found, signing: nil, to: folder, anchors: [tsa.caCertificate])
        let check = try Tools.run(Tools.openssl, ["ts", "-verify", "-data", "Roman.pdf", "-in", "Zeitstempel – Dienst A.tsr",
                                                  "-CAfile", tsa.caPEM.path, "-untrusted", "Zertifikate – Dienst A.pem"], in: folder)
        XCTAssertTrue((check.text + check.errors).contains("Verification: OK"), check.errors)
        XCTAssertTrue(try read("LIESMICH.txt", in: folder).contains(Data("%PDF-Probe".utf8).sha256.hex))
    }

    func testStampsTravelThroughTheServer() async throws {
        let tsa = try tsa()
        let server = temp.appendingPathComponent("server.git")
        try await git(["init", "--quiet", "--bare", "--initial-branch=main", server.path], in: temp)
        let macA = try await Book.create(at: temp.appendingPathComponent("A/Buch.stet"), title: "Buch", author: "Test")
        try await macA.connect(to: server.path, device: "macA")
        try await macA.queueVersionStamp()
        _ = await macA.processStamps(authorities: [authorities[0]], client: tsa.client)
        _ = try await macA.sync(device: "macA")

        let macB = try await Book.clone(from: server.path, to: temp.appendingPathComponent("B/Buch.stet"))
        let headCommit = await macB.git.headCommit()
        let head = try XCTUnwrap(headCommit)
        let onB = await macB.stamps()[head]?.map(\.authority)
        XCTAssertEqual(onB, ["Dienst A"])

        // Both Macs stamp the same version; after syncing both have both stamps.
        try await macB.queueVersionStamp()
        _ = await macB.processStamps(authorities: [authorities[1]], client: tsa.client)
        _ = try await macB.sync(device: "macB")
        _ = try await macA.sync(device: "macA")
        let onA = await macA.stamps()[head]?.map(\.authority).sorted()
        XCTAssertEqual(onA, ["Dienst A", "Dienst B"])
    }

    // MARK: Real services (only on request)

    func testLiveAuthorities() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STET_LIVE_TSA"] == "1", "set STET_LIVE_TSA=1 to ask the real services")
        // A random test checksum: nothing of any book is sent.
        let digest = Data(UUID().uuidString.utf8).sha256
        for authority in TimestampAuthority.defaults {
            let stamp = try await TimestampClient().stamp(digest, at: authority)
            let verification = try RFC3161.verify(stamp.response)
            XCTAssertTrue(verification.trusted, "\(authority.name): \(verification.trustProblem ?? "")")
            XCTAssertLessThan(abs(stamp.time.timeIntervalSinceNow), 300)
            let reply = temp.appendingPathComponent("\(authority.name).tsr"), certs = temp.appendingPathComponent("\(authority.name).pem")
            try stamp.response.write(to: reply)
            try Data(RFC3161.pem(verification.embedded).utf8).write(to: certs)
            // The command from the proof's read-me, with macOS's openssl and (if installed) a current OpenSSL.
            var verdicts: [String] = []
            for tool in [Tools.openssl, URL(fileURLWithPath: "/opt/homebrew/opt/openssl/bin/openssl")] where FileManager.default.isExecutableFile(atPath: tool.path) {
                let check = try Tools.run(tool, ["ts", "-verify", "-digest", digest.hex, "-in", reply.path, "-CAfile", "/etc/ssl/cert.pem", "-untrusted", certs.path])
                let version = try Tools.run(tool, ["version"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
                verdicts.append("\(version.split(separator: " ").prefix(2).joined(separator: " ")): " + ((check.text + check.errors).contains("Verification: OK") ? "OK" : "FAILED"))
            }
            XCTAssertTrue(verdicts.contains { $0.hasSuffix(": OK") }, "\(authority.name): \(verdicts)")
            print("LIVE \(authority.name): \(stamp.response.count) bytes, signer \(verification.signer), root \(verification.chain.count) deep; openssl: \(verdicts.joined(separator: ", "))")
        }
    }
}
