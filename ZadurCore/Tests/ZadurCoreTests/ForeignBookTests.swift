import Foundation
import XCTest
@testable import ZadurCore

/// A book from someone else brings its own `.git`. Nothing in there may start a program on this
/// Mac: not its git settings, not its hooks, not a server or key it names, not a repository
/// nested in it. Every trap here would leave a file `RAN-<name>` behind.
final class ForeignBookTests: TempDirTestCase {
    private var traps: URL { temp.appendingPathComponent("traps") }

    /// A shell command that gives the trap away, then goes on like the real tool would.
    private func trap(_ name: String, then: String = "cat") -> String {
        "touch '\(traps.path)/RAN-\(name)'; \(then)"
    }

    private func sprung() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: traps.path).sorted()
    }

    private func script(_ name: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(trap(name, then: "exit 0"))\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// A real book with history, then everything a stranger could plant in it.
    private func makeForeignBook() async throws -> URL {
        try FileManager.default.createDirectory(at: traps, withIntermediateDirectories: true)
        let url = temp.appendingPathComponent("Fremd.crea")
        let book = try await Book.create(at: url, title: "Fremd", author: "Jemand")
        var scene = try book.readScene(book.manifest.sceneIDs[0])
        scene.body = "Erster Absatz.\n\nZweiter Absatz.\n"
        try book.writeScene(scene)
        try write("*.md filter=x diff=x merge=x\n*.yaml filter=x diff=x merge=x\n", to: ".gitattributes", in: url)

        // A repository nested in the book, as a submodule.
        let nested = url.appendingPathComponent("beilagen/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try await git(["init", "--quiet"], in: nested)
        try write("x\n", to: "x.txt", in: nested)
        try await git(["add", "--all"], in: nested)
        try await git(["commit", "--quiet", "-m", "x"], in: nested)
        try write("[submodule \"n\"]\n\tpath = beilagen/nested\n\turl = ./n\n\tignore = none\n", to: ".gitmodules", in: url)
        _ = try await book.saveVersion()
        try script("nested-fsmonitor", at: nested.appendingPathComponent("fs.sh"))
        try await git(["config", "core.fsmonitor", nested.appendingPathComponent("fs.sh").path], in: nested)

        let gitFolder = url.appendingPathComponent(".git")
        // A "server" inside the book, with a hook for whoever pushes to it.
        let server = gitFolder.appendingPathComponent("server.git")
        try await git(["init", "--quiet", "--bare", "--initial-branch=main", server.path], in: temp)
        for hook in ["pre-receive", "update", "post-receive", "post-update"] {
            try script("server-\(hook)", at: server.appendingPathComponent("hooks/\(hook)"))
        }
        for hook in ["pre-commit", "post-commit", "commit-msg", "post-checkout", "post-merge", "pre-push", "post-index-change", "reference-transaction"] {
            try script("hook-\(hook)", at: gitFolder.appendingPathComponent("hooks/\(hook)"))
        }
        let include = gitFolder.appendingPathComponent("more")
        try Data("[filter \"y\"]\n\tclean = \(trap("include"))\n[hook \"inc\"]\n\tevent = pre-commit\n\tcommand = \(trap("include-hook", then: "true"))\n".utf8).write(to: include)
        try Data("[core]\n\tfsmonitor = \(gitFolder.path)/hooks/pre-commit\n".utf8).write(to: gitFolder.appendingPathComponent("config.worktree"))
        let settings: [(String, String)] = [
            ("filter.x.clean", trap("filter-clean")), ("filter.x.smudge", trap("filter-smudge")), ("filter.x.required", "true"),
            ("diff.x.command", trap("diff-command", then: "true")), ("diff.x.textconv", trap("textconv")), ("diff.external", trap("diff-external", then: "true")),
            ("merge.x.driver", trap("merge-driver", then: "true")), ("core.fsmonitor", gitFolder.appendingPathComponent("hooks/pre-commit").path),
            ("core.sshCommand", trap("ssh", then: "false")), ("core.gitProxy", trap("proxy")), ("core.askPass", trap("askpass")),
            ("core.editor", trap("editor", then: "true")), ("core.pager", trap("pager")), ("core.alternateRefsCommand", trap("altrefs")),
            ("core.hooksPath", gitFolder.appendingPathComponent("hooks").path), ("credential.helper", "!" + trap("credential", then: "true")),
            ("gpg.program", gitFolder.appendingPathComponent("hooks/pre-commit").path), ("gpg.ssh.program", gitFolder.appendingPathComponent("hooks/pre-commit").path),
            ("log.showSignature", "true"), ("commit.gpgsign", "true"), ("gc.recentObjectsHook", trap("gc", then: "true")), ("gc.auto", "1"),
            ("hook.planted.command", trap("config-hook", then: "true")), ("hook.planted.event", "pre-commit"),
            ("uploadpack.packObjectsHook", trap("pack-objects")), ("protocol.ext.allow", "always"),
            ("remote.origin.url", server.path), ("remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"),
            ("remote.origin.uploadpack", trap("uploadpack", then: "git-upload-pack")), ("remote.origin.receivepack", trap("receivepack", then: "git-receive-pack")),
            ("remote.origin.pushurl", "ext::sh -c touch% \(traps.path)/RAN-ext"),
            ("url.\(server.path).insteadOf", "https://example.org/"), ("include.path", include.path),
            ("extensions.worktreeConfig", "true"), ("stet.sshKey", "x'; touch '\(traps.path)/RAN-key"),
            ("user.name", "Jemand"), ("branch.main.description", "bleibt"),
        ]
        for (key, value) in settings { try await git(["config", key, value], in: url) }
        XCTAssertEqual(try sprung(), [], "setting the traps must not spring them")
        return url
    }

    /// Everything Zadur does with a book on its own or on ⌘S.
    private func useEverything(_ book: Book) async throws {
        _ = try await book.startHistoryIfNeeded()
        await book.adoptCreaNames()
        _ = await HealthCheck.run(book)
        let id = book.manifest.sceneIDs[0]
        func edit(_ text: String) throws {
            var scene = try book.readScene(id)
            scene.body = text
            try book.writeScene(scene)
        }
        _ = try await book.git.changedPaths()
        try edit("Geändert.\n\nZweiter Absatz.\n")
        _ = try await book.snapshot(device: "mac")
        _ = try await book.saveVersion()
        _ = try await book.history(ofScene: id, device: "mac")
        _ = try await book.git.log()
        _ = await book.stamps()
        let head = await book.git.headCommit()
        _ = await book.signatures(of: [head ?? "HEAD"])
        _ = try await book.receipt(for: "HEAD")
        // An experiment that conflicts with the main version.
        let main = await book.mainBranch()
        try await book.startExperiment(named: "Anders", carryChanges: false)
        let branch = await book.currentBranch()
        try edit("Im Experiment.\n\nZweiter Absatz, anders.\n")
        _ = try await book.saveVersion()
        try await book.switchTo(main)
        try edit("In der Hauptfassung.\n\nZweiter Absatz.\n")
        _ = try await book.saveVersion()
        _ = try await book.adopt(branch)
        _ = try? await book.currentConflicts()
        try? await book.abortAdoption()
        _ = try? await book.setMilestone(name: "Stand", note: "")
    }

    func testNothingInAForeignBookRuns() async throws {
        let url = try await makeForeignBook()
        let book = try Book(url: url)
        do {
            try await useEverything(book)
        } catch {
            XCTFail("\(error) – traps: \(try sprung())")
        }
        XCTAssertEqual(try sprung(), [])
    }

    func testTheWritersOwnSettingsStayAndTheRestIsKeptAside() async throws {
        let url = try await makeForeignBook()
        let original = try Data(contentsOf: url.appendingPathComponent(".git/config"))
        var reported: [String] = []
        RepositoryGuard.onRemoved = { _, names in reported += names }
        defer { RepositoryGuard.onRemoved = nil }
        let book = try Book(url: url)
        let name = try await book.git.run(["config", "user.name"]).string
        XCTAssertEqual(name, "Jemand\n")
        let described = try await book.git.run(["config", "branch.main.description"]).string
        XCTAssertEqual(described, "bleibt\n")
        let server = await book.remoteURL()
        XCTAssertEqual(server, url.appendingPathComponent(".git/server.git").path)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent(".git/config.entfernt")), original)
        XCTAssertTrue(reported.contains("filter.x.clean") && reported.contains("hook.planted.command") && reported.contains("include.path"))
        XCTAssertFalse(reported.contains("user.name"))

        // Settings that come later (a sync service, another program) are caught as well.
        reported = []
        try await git(["config", "filter.z.clean", trap("later")], in: url)
        try write("*.md filter=z\n", to: ".gitattributes", in: url)
        _ = try await book.saveVersion()
        XCTAssertEqual(reported, ["filter.z.clean"])
        XCTAssertEqual(try sprung(), [])
    }

    func testServerOfAForeignBookIsAskedAboutFirst() async throws {
        let saved = ServerTrust.store
        ServerTrust.store = MemoryServerTrust()
        defer { ServerTrust.store = saved }
        let url = try await makeForeignBook()
        let book = try Book(url: url)
        let unknown = await book.untrustedServer()
        XCTAssertEqual(unknown, url.appendingPathComponent(".git/server.git").path)
        do {
            _ = try await book.sync(device: "mac")
            XCTFail("must not connect")
        } catch let error as SyncError {
            XCTAssertEqual(error, .untrustedServer(unknown ?? ""))
        }
        XCTAssertEqual(try sprung(), [])

        // The reason for asking: whoever sends to that "server" runs its hooks.
        ServerTrust.store.trust(unknown ?? "")
        _ = try await book.sync(device: "mac")
        XCTAssertTrue(try sprung().contains("RAN-server-post-receive"), "the trap works")
        for name in try sprung() { try FileManager.default.removeItem(at: traps.appendingPathComponent(name)) }

        // A server the writer agrees to (an ordinary one) works.
        let plain = temp.appendingPathComponent("eigener.git")
        try await git(["init", "--quiet", "--bare", "--initial-branch=main", plain.path], in: temp)
        try await book.git.run(["remote", "set-url", "origin", plain.path])
        await book.trustServer()
        let result = try await book.sync(device: "mac")
        XCTAssertTrue(result.pushed, "\(result)")
        XCTAssertEqual(try sprung(), [])
        // A second address added next to it counts too.
        try await book.git.run(["config", "--add", "remote.origin.url", "https://fremd.example/buch.git"])
        let second = await book.untrustedServer()
        XCTAssertNotNil(second)
    }

    func testKeyOfAForeignBookIsNotUsed() async throws {
        let url = try await makeForeignBook()
        let book = try Book(url: url)
        let key = await book.zadurKey()
        XCTAssertNil(key)
        let environment = await book.networkEnvironment()
        XCTAssertEqual(environment["GIT_SSH_COMMAND"], "ssh " + Book.keySSHOptions)
        XCTAssertFalse(SSHKey.isOwnKey("/etc/hosts"))
        XCTAssertFalse(SSHKey.isOwnKey(SSHKey.folder.path + "/../x"))
        XCTAssertFalse(SSHKey.isOwnCommand("ssh -i 'x'; touch y"))
    }

    func testHistoryThatPointsElsewhereIsRefused() async throws {
        let url = try await makeForeignBook()
        let git = url.appendingPathComponent(".git")
        let outside = temp.appendingPathComponent("outside.git")
        func expectRefusal(_ what: String) async {
            do {
                _ = try await (try Book(url: url)).git.run(["rev-parse", "HEAD"])
                XCTFail(what)
            } catch {
                XCTAssertTrue(error is RepositoryGuard.Problem, "\(what): \(error)")
            }
        }
        try Data("../../x\n".utf8).write(to: git.appendingPathComponent("commondir"))
        await expectRefusal("commondir")
        try FileManager.default.removeItem(at: git.appendingPathComponent("commondir"))
        try FileManager.default.moveItem(at: git, to: outside)
        try FileManager.default.createSymbolicLink(at: git, withDestinationURL: outside)
        await expectRefusal("symlink")
        try FileManager.default.removeItem(at: git)
        try Data("gitdir: \(outside.path)\n".utf8).write(to: git)
        await expectRefusal("git file")
        XCTAssertEqual(try sprung(), [])
    }

    /// Without `.git`, git would take a folder that looks like a bare repository for one.
    func testBookThatLooksLikeABareRepository() async throws {
        let url = try await makeForeignBook()
        let git = url.appendingPathComponent(".git")
        for name in ["HEAD", "config", "objects", "refs"] {
            try FileManager.default.moveItem(at: git.appendingPathComponent(name), to: url.appendingPathComponent(name))
        }
        try FileManager.default.removeItem(at: git)
        let book = try Book(url: url)
        let head = await book.git.headCommit()
        XCTAssertNil(head)
        let started = try await book.startHistoryIfNeeded()
        XCTAssertTrue(started)
        try await useEverything(book)
        XCTAssertEqual(try sprung(), [])
    }

    func testImportingAForeignFolderRunsNothing() async throws {
        let url = try await makeForeignBook()
        try write("Noch nicht gesichert.\n", to: "neu.md", in: url)
        let destination = temp.appendingPathComponent("Importiert.crea")
        _ = try await Importer.importFolder(url, to: destination)
        XCTAssertEqual(try sprung(), [])
        let imported = try Book(url: destination)
        let texts = imported.manifest.sceneIDs.compactMap { try? imported.readScene($0).body }.joined()
        XCTAssertTrue(texts.contains("Noch nicht gesichert."), "uncommitted work comes along")
    }
}
