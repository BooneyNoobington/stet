import Foundation

/// Runs the small command-line tools Zadur relies on (ssh-keygen, openssl, smimesign, gpg …).
enum Tools {
    struct Result {
        let status: Int32
        let output: Data
        let errors: String
        var text: String { String(decoding: output, as: UTF8.self) }
    }

    static func run(
        _ executable: URL,
        _ arguments: [String],
        input: Data? = nil,
        environment: [String: String] = [:],
        in directory: URL? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        var out = Data(), err = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            out = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        err = stderr.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: out, errors: String(decoding: err, as: UTF8.self))
    }

    static func runAsync(
        _ executable: URL,
        _ arguments: [String],
        input: Data? = nil,
        environment: [String: String] = [:],
        in directory: URL? = nil
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Swift.Result { try run(executable, arguments, input: input, environment: environment, in: directory) })
            }
        }
    }

    /// A tool from Homebrew, GPG Suite or the system, whichever is installed.
    static func find(_ name: String, extraFolders: [String] = []) -> URL? {
        for folder in extraFolders {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return Exporter.tool(name)
    }

    static let sshKeygen = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    static let sshAdd = URL(fileURLWithPath: "/usr/bin/ssh-add")
    static let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
}
