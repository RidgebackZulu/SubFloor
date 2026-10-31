import Foundation

/// Finds an agent's command-line tool and runs its "add MCP server" command, for the Setup tab's Add button.
/// The command runs directly, never through a shell, so nothing in the URL or token is interpreted.
@MainActor
enum AgentInstaller {
    nonisolated static let timeout: Duration = .seconds(30)

    /// Where agents' tools usually live; a GUI app's PATH has none of them.
    nonisolated static var searchDirectories: [String] {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin"]
    }

    /// `executable` as an absolute path, else in `searchDirectories`, else on the login shell's PATH. Safe off
    /// the main actor; the shell lookup can take a moment.
    nonisolated static func locate(_ executable: String) -> URL? {
        let fm = FileManager.default
        if executable.hasPrefix("/") {
            return fm.isExecutableFile(atPath: executable) ? URL(fileURLWithPath: executable) : nil
        }
        // A bare name only: it is passed to the shell as an argument, never as script text.
        guard !executable.isEmpty, executable.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else {
            return nil
        }
        for dir in searchDirectories where fm.isExecutableFile(atPath: "\(dir)/\(executable)") {
            return URL(fileURLWithPath: "\(dir)/\(executable)")
        }
        let found = Runner.run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", #"command -v -- "$1""#, "zsh", executable],
                               stdin: nil, environment: nil, timeout: .seconds(5))
        let path = found.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard found.status == 0, path.hasPrefix("/"), fm.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// `locate` on a background thread.
    nonisolated static func find(_ executable: String) async -> URL? {
        await offCooperativePool { locate(executable) }
    }

    /// Runs `install`'s steps in order, each with a 30 s limit, stopping at the first failure not allowed to
    /// fail. `ok` is every such step exiting 0; `output` is their stdout and stderr together.
    static func run(_ install: AgentInstall) async -> (ok: Bool, output: String) {
        await offCooperativePool {
            guard let url = locate(install.executable) else {
                return (false, "\(install.executable) not found on this Mac")
            }
            var env = ProcessInfo.processInfo.environment
            // Node-based tools start with `#!/usr/bin/env node`, so their own folder must be on the PATH.
            let path = [url.deletingLastPathComponent().path] + searchDirectories + [env["PATH"] ?? "/usr/bin:/bin"]
            env["PATH"] = path.joined(separator: ":")
            var outputs: [String] = []
            for step in install.steps {
                let result = Runner.run(url, step.arguments, stdin: step.stdin, environment: env, timeout: timeout)
                let ok = result.status == 0 && !result.timedOut
                if !ok, step.mayFail { continue }
                var output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.timedOut {
                    output += (output.isEmpty ? "" : "\n") + "Stopped after \(timeout.components.seconds) s."
                }
                if !output.isEmpty { outputs.append(output) }
                if !ok { return (false, outputs.joined(separator: "\n")) }
            }
            return (true, outputs.joined(separator: "\n"))
        }
    }

    /// Runs `body`, which blocks while a process runs, on a GCD thread rather than one of Swift's few
    /// cooperative ones.
    private nonisolated static func offCooperativePool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: body()) }
        }
    }
}

/// Runs a process to completion, collecting its output, killing it at the time limit.
private enum Runner {
    struct Result {
        var status: Int32?
        var output: String
        var timedOut = false
    }

    /// Blocks the calling thread: call it off the main actor.
    static func run(_ url: URL, _ arguments: [String], stdin: String?, environment: [String: String]?,
                    timeout: Duration) -> Result {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        let collected = Collected()
        let finished = DispatchSemaphore(value: 0)
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                finished.signal()
            } else {
                collected.append(chunk)
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return Result(status: nil, output: "Could not run \(url.path): \(error.localizedDescription)")
        }
        if let stdin {
            // A command that exits without reading must not take SubFloor down with SIGPIPE.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        var timedOut = false
        if exited.wait(timeout: .now() + seconds) == .timedOut {
            timedOut = true
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
        }
        // The rest of the output; a child it left running may hold the pipe open, so wait only briefly.
        _ = finished.wait(timeout: .now() + 1)
        out.fileHandleForReading.readabilityHandler = nil
        let data = collected.data
        return Result(status: process.isRunning ? nil : process.terminationStatus,
                      output: String(decoding: data, as: UTF8.self), timedOut: timedOut)
    }

    /// Output gathered on the pipe's queue.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        var data: Data { lock.withLock { bytes } }

        func append(_ chunk: Data) {
            lock.withLock { bytes.append(chunk) }
        }
    }
}
