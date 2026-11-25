import Foundation
import ZadurCore

/// Syncing the open book with its server.
extension BookSession {
    enum SyncState: Equatable {
        case off
        case syncing
        case done(Date)
        /// The server has versions from another Mac; bring them in when ready.
        case serverHasNew
        /// Both this Mac and the server have new versions of the main version.
        case needsMerge
        case offline(String)
        /// The book names a server nobody has set up or agreed to on this Mac.
        case untrusted(String)
        case warning(String)
    }

    var isConnected: Bool { serverURL != nil }

    func loadServer() async {
        serverURL = await book.remoteURL()
        zadurKey = await book.zadurKey()
        syncState = serverURL == nil ? .off : syncState
        if let unknown = await book.untrustedServer() { syncState = .untrusted(unknown) }
    }

    /// The writer knows the server this book names: from now on it's used like any other.
    func trustServer() async {
        await book.trustServer()
        syncState = .off
        await syncNow()
    }

    /// The login kept in the keychain for an address (its user name; the password stays there).
    func storedLogin(for url: String) -> ServerLogin? {
        ServerEndpoint.parse(url).flatMap { ServerLogins.store.login(for: $0) }
    }

    func forgetLogin(for url: String) {
        guard let endpoint = ServerEndpoint.parse(url) else { return }
        try? ServerLogins.store.remove(for: endpoint)
    }

    /// Creates the repository on a server with only git and SSH. Returns an error message, or nil.
    func createServerRepository(_ url: String, login: ServerLogin?) async -> String? {
        do {
            try await Book.createRepository(at: url, login: login)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Creates a passphrase-less key for this book (see SSHKey). Returns an error message, or nil.
    func createKey() async -> String? {
        do {
            zadurKey = try await book.createZadurKey()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeKey() async {
        try? await book.removeZadurKey()
        zadurKey = nil
    }

    /// Full sync: brings in what the server has. Only when the writer isn't mid-sentence
    /// (on opening, or on request); the editor's text is written to disk first.
    func syncNow() async {
        await runSync(integrate: true)
    }

    /// After saving a version: send, and only report what the server has new.
    func scheduleSync() {
        guard isConnected else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.runSync(integrate: false)
        }
    }

    private func runSync(integrate: Bool) async {
        guard isConnected, adoption == nil, syncState != .syncing else { return }
        if case .untrusted = syncState { return }
        syncState = .syncing
        if integrate {
            await persist()
            isChangingFiles = true
        }
        defer { isChangingFiles = false }
        do {
            let result = try await book.sync(device: DeviceID.current, integrate: integrate)
            if result.changedFiles { await reloadAfterVersionChange() } else { await refreshVersions() }
            if result.needsMerge {
                syncState = .needsMerge
            } else if result.serverHasNew {
                syncState = .serverHasNew
            } else if let warning = result.warnings.first {
                syncState = .warning(warning)
            } else {
                syncState = .done(Date())
            }
            if result.pulledVersions > 0 {
                showToast(Toast(message: result.pulledVersions == 1 ? "1 Version vom Server geholt" : "\(result.pulledVersions) Versionen vom Server geholt"))
            }
        } catch SyncError.untrustedServer(let address) {
            syncState = .untrusted(address)
        } catch let error as SyncError {
            syncState = .offline(error.localizedDescription)
        } catch {
            syncState = .warning(error.localizedDescription)
        }
    }

    func checkServer(_ url: String, login: ServerLogin? = nil) async -> Result<RemoteCheck, Error> {
        do {
            return .success(try await book.checkRemote(url, login: login))
        } catch {
            return .failure(error)
        }
    }

    /// Connects and syncs. Returns an error message, or nil on success.
    func connectServer(_ url: String, login: ServerLogin? = nil) async -> String? {
        await persist()
        isChangingFiles = true
        defer { isChangingFiles = false }
        do {
            let result = try await book.connect(to: url, device: DeviceID.current, login: login)
            serverURL = await book.remoteURL()
            if result.changedFiles { await reloadAfterVersionChange() }
            syncState = result.needsMerge ? .needsMerge : result.warnings.first.map(SyncState.warning) ?? .done(Date())
            showToast(Toast(message: "Mit dem Server verbunden"))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func disconnectServer() async {
        try? await book.disconnect()
        serverURL = nil
        syncState = .off
    }

    /// Merges the server's main version into this Mac's, with the same decision window as adopting.
    func mergeWithServer() async {
        await persist()
        isBusy = true
        defer { isBusy = false }
        do {
            switch try await book.mergeWithServer() {
            case .adopted, .nothingNew:
                await reloadAfterVersionChange()
                syncState = .done(Date())
                showToast(Toast(message: "Mit dem Server zusammengeführt"))
                scheduleSync()
            case .conflicts(let conflicts):
                adoption = Adoption(branch: "\(Book.remoteName)/\(mainBranch)", name: "Server", conflicts: conflicts,
                                    mainLabel: "Dieser Mac", otherLabel: "Server", fromServer: true)
                sheet = .conflicts
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var syncStatusText: String? {
        switch syncState {
        case .off: nil
        case .syncing: "Server: wird abgeglichen …"
        case .done(let date): "Server: abgeglichen \(date.formatted(date: .omitted, time: .shortened))"
        case .serverHasNew: "Server: neue Versionen verfügbar"
        case .needsMerge: "Server: zusammenführen nötig"
        case .offline: "Server: nicht erreichbar"
        case .untrusted: "Server: noch nicht bestätigt"
        case .warning: "Server: mit Hinweis abgeglichen"
        }
    }

    var syncStatusDetail: String? {
        switch syncState {
        case .offline(let message), .warning(let message): message
        default: serverURL
        }
    }
}
