//  CommandRunner.swift
//  Aurora — 轻量命令执行层
//
//  存储模块里所有「原生 Swift 不好干」的活都走这里：du 统计目录体积、brew / docker 这类
//  外部 CLI。统一处理超时、非交互、输出截断，避免某个命令把界面卡死。

import Foundation

struct CommandResult: Sendable {
    var status: Int32 = -1
    var output: String = ""
    var error: String = ""
    var timedOut = false

    var ok: Bool { status == 0 && !timedOut }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func set(_ value: Data) {
        lock.lock(); storage = value; lock.unlock()
    }
}

enum CommandRunner {
    /// 常见 CLI 目录：GUI App 的 PATH 很短，brew 装的东西默认都看不到
    static let searchPaths = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin", "/usr/local/sbin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin"
    ]

    /// 找可执行文件；GUI 进程的 PATH 不含 Homebrew，这里自己补
    static func locate(_ tool: String) -> String? {
        if tool.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
        }
        var directories = searchPaths
        if let extra = ProcessInfo.processInfo.environment["PATH"] {
            directories += extra.split(separator: ":").map(String.init)
        }
        for directory in directories {
            let full = directory + "/" + tool
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    static func exists(_ tool: String) -> Bool { locate(tool) != nil }

    /// 同步执行，务必在后台线程调用
    static func runSync(_ executable: String, _ arguments: [String],
                        timeout: TimeInterval = 30, environment: [String: String]? = nil) -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return CommandResult(status: -1, error: "missing: \(executable)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPaths.joined(separator: ":") + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        // du / find 的输出不该被本地化，固定成 C 语言
        env["LC_ALL"] = "C"
        if let environment { env.merge(environment) { _, new in new } }
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch {
            return CommandResult(status: -1, error: error.localizedDescription)
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning { process.terminate() }
        }
        timer.resume()

        // stdout / stderr 必须同时抽干：只读一路时，另一路写满 64KB 缓冲区会互相等死
        // （du 在受限目录下会刷大量 Permission denied，正好能把它卡住）
        let errorBox = ErrorBox()
        let drain = DispatchGroup()
        drain.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            errorBox.set(data)
            drain.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        drain.wait()
        process.waitUntilExit()
        timer.cancel()

        return CommandResult(
            status: process.terminationStatus,
            output: String(data: outData, encoding: .utf8) ?? "",
            error: String(data: errorBox.data, encoding: .utf8) ?? "",
            timedOut: process.terminationReason == .uncaughtSignal
        )
    }

    static func run(_ executable: String, _ arguments: [String],
                    timeout: TimeInterval = 30) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(executable, arguments, timeout: timeout))
            }
        }
    }

    /// 在终端里跑一条命令（用于把第三方 CLI 交给用户自己确认执行）
    @MainActor
    static func openInTerminal(_ command: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "\(command.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
