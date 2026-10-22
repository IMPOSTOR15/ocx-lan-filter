import Foundation

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var output: String
    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

public protocol CommandRunner: Sendable {
    func run(_ launchPath: String, _ args: [String], environment: [String: String]?) async -> CommandResult
}

public struct ProcessRunner: CommandRunner {
    public init() {}
    public func run(_ launchPath: String, _ args: [String], environment: [String: String]? = nil) async -> CommandResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: launchPath)
                p.arguments = args
                if let environment { p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch {
                    cont.resume(returning: CommandResult(status: 127, output: "\(error)"))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: CommandResult(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

public enum ServiceState: Equatable, Sendable {
    case notInstalled
    case stopped
    case running(pid: Int?)
}

public struct ServiceController: Sendable {
    public static let label = "com.local.ocx-lan-filter"
    private let runner: CommandRunner
    private let uid: UInt32
    private let plist: URL

    public init(runner: CommandRunner = ProcessRunner(), uid: UInt32 = getuid(),
                plist: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/LaunchAgents/\(ServiceController.label).plist")) {
        self.runner = runner
        self.uid = uid
        self.plist = plist
    }

    var domain: String { "gui/\(uid)" }
    var target: String { "\(domain)/\(Self.label)" }

    public static func parse(_ r: CommandResult) -> ServiceState {
        guard r.status == 0 else { return .notInstalled }
        var pid: Int?
        var running = false
        for raw in r.output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("pid = "), pid == nil { pid = Int(line.dropFirst(6)) }
            if line.hasPrefix("state = running") { running = true }
        }
        return running ? .running(pid: pid) : .stopped
    }

    public func state() async -> ServiceState {
        var r = await runner.run("/bin/launchctl", ["print", target], environment: nil)
        if r.status != 0, !FileManager.default.fileExists(atPath: plist.path) { r.status = 113 }
        return Self.parse(r)
    }

    public func restart() async -> CommandResult {
        let r = await runner.run("/bin/launchctl", ["kickstart", "-k", target], environment: nil)
        if r.status != 0, FileManager.default.fileExists(atPath: plist.path) {
            return await runner.run("/bin/launchctl", ["bootstrap", domain, plist.path], environment: nil)
        }
        return r
    }

    public func stop() async -> CommandResult {
        await runner.run("/bin/launchctl", ["bootout", target], environment: nil)
    }

    public func start() async -> CommandResult {
        await runner.run("/bin/launchctl", ["bootstrap", domain, plist.path], environment: nil)
    }

    /// Runs the bundled, idempotent install.sh (copies filter.py, keeps the key and config, re-registers launchd).
    public func install(scriptDirectory: URL) async -> CommandResult {
        await runner.run("/bin/sh", [scriptDirectory.appendingPathComponent("install.sh").path], environment: nil)
    }
}
