import Foundation

public enum Shell {
    /// GUI apps get a minimal PATH; add the usual CLI locations.
    public static let searchPath: String = {
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/bin",
                     "\(home)/.npm-global/bin", "\(home)/.bun/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (current + extra).filter { seen.insert($0).inserted }.joined(separator: ":")
    }()

    /// Environment for child processes. Forge tokens are stripped so they never reach an engine.
    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        // ANTHROPIC_*/OPENAI keys would switch the CLIs from your subscription login to API billing.
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "GITLAB_TOKEN", "GITLAB_PRIVATE_TOKEN", "GL_TOKEN", "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] {
            env[k] = nil
        }
        return env
    }

    private static var resolved: [String: String] = [:]
    private static let lock = NSLock()

    public static func which(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let r = resolved[name] { return r }
        for dir in searchPath.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { resolved[name] = p; return p }
        }
        // Last resort: ask a login shell (picks up nvm/asdf shims).
        if let out = try? capture(["/bin/zsh", "-lc", "command -v \(name)"]), out.status == 0 {
            let p = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.hasPrefix("/") { resolved[name] = p; return p }
        }
        return nil
    }

    public struct Output { public var status: Int32; public var stdout: String; public var stderr: String }

    /// Short synchronous command (auth lookups). Not for engines. Killed after `timeout`
    /// so a slow login shell or a stuck glab can never hang the caller.
    public static func capture(_ argv: [String], timeout: TimeInterval = 15) throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        var o = Data(), e = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        if g.wait(timeout: .now() + timeout) == .timedOut {
            // ponytail: reader threads stay parked if a grandchild still holds the pipe; harmless for a few short calls.
            p.terminate()
            throw RunError.timeout
        }
        p.waitUntilExit()
        return Output(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }

    public enum RunError: Error { case timeout, cancelled }

    /// Long-running child with stdout/stderr to files, timeout and cancellation (terminate, then kill).
    public static func run(_ argv: [String], cwd: URL, stdin: Data?, stdout: URL, stderr: URL, timeout: TimeInterval) async throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.currentDirectoryURL = cwd
        p.environment = environment
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        if !FileManager.default.fileExists(atPath: stderr.path) { FileManager.default.createFile(atPath: stderr.path, contents: nil) }
        let outH = try FileHandle(forWritingTo: stdout)
        let errH = try FileHandle(forWritingTo: stderr)
        errH.seekToEndOfFile()
        p.standardOutput = outH
        p.standardError = errH
        let inPipe = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        defer { try? outH.close(); try? errH.close() }

        let finished = AsyncStream<Int32> { cont in
            p.terminationHandler = { cont.yield($0.terminationStatus); cont.finish() }
        }
        try p.run()
        if let stdin {
            inPipe.fileHandleForWriting.write(stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        let watchdog = Task.detached {
            while p.isRunning {
                if Task.isCancelled || Date() > deadline {
                    p.terminate()
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        let cancelled = { Task.isCancelled }
        let status = await withTaskCancellationHandler {
            var s: Int32 = -1
            for await code in finished { s = code }
            return s
        } onCancel: {
            watchdog.cancel()
            p.terminate()
        }
        watchdog.cancel()
        if cancelled() { throw RunError.cancelled }
        if Date() > deadline { throw RunError.timeout }
        return status
    }

    /// Split a user-entered command line ("gate run --") into argv, honouring simple quotes.
    public static func split(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        for ch in s {
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == " " { if !cur.isEmpty { out.append(cur); cur = "" } }
            else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out.map { ($0 as NSString).expandingTildeInPath }
    }
}
