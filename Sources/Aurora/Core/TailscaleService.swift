//  TailscaleService.swift
//  Aurora — Tailscale 组网
//
//  两条路都走：本机装了官方 App 就复用它的 CLI 读状态、开关、切出口节点；
//  没装但装了 tailscaled（例如 brew install tailscale），就用 userspace 模式自己拉起一个
//  独立的 tailscaled，并开一个本机 SOCKS5 给代理做组网出站。
//  都没有时不伪造开关，只给安装引导。

import AppKit
import Foundation
import NetworkProxyKit

@MainActor
final class TailscaleService: ObservableObject {
    enum Provider: String {
        case officialApp
        case userspace
        case remoteCLI
        case unavailable
    }

    @Published private(set) var provider: Provider = .unavailable
    @Published private(set) var snapshot = TailscaleSnapshot.empty
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var loginURL: String?
    @Published private(set) var socksPort: Int?
    @Published private(set) var daemonRunning = false
    @Published private(set) var cliVersion = ""
    @Published private(set) var detecting = true

    private var cli: String?
    private var daemonPath: String?
    private var daemonProcess: Process?
    private var timer: Timer?
    private var visible = false

    static var directory: URL { SystemProxyService.directory.appendingPathComponent("tailscale", isDirectory: true) }
    var socketURL: URL { Self.directory.appendingPathComponent("tailscaled.sock") }
    var stateURL: URL { Self.directory.appendingPathComponent("tailscaled.state") }

    init() {
        Task { await probe() }
    }

    deinit {
        timer?.invalidate()
        if let process = daemonProcess, process.isRunning { process.terminate() }
    }

    // MARK: - 能力探测

    /// 探测要跑外部命令（`tailscale version` 可能挂住），放到后台，别卡启动。
    private struct Probe {
        var provider: Provider = .unavailable
        var cli: String?
        var daemon: String?
        var version = ""
    }

    private func probe() async {
        let result = await Task.detached(priority: .utility) { Self.detect() }.value
        cli = result.cli
        daemonPath = result.daemon
        cliVersion = result.version
        provider = result.provider
        detecting = false
        if provider != .unavailable { await refresh() }
    }

    private nonisolated static func detect() -> Probe {
        var probe = Probe()
        let official = "/Applications/Tailscale.app/Contents/MacOS/tailscale"
        if FileManager.default.isExecutableFile(atPath: official) {
            probe.provider = .officialApp
            probe.cli = official
            return probe
        }
        // 本机 tailscaled（brew 装的 OSS 版）：可以自己管进程
        if let daemon = CommandRunner.locate("tailscaled"), let tailscale = CommandRunner.locate("tailscale") {
            let check = CommandRunner.runSync(tailscale, ["version"], timeout: 6)
            if check.ok {
                probe.provider = .userspace
                probe.cli = tailscale
                probe.daemon = daemon
                probe.version = versionText(check.output)
                return probe
            }
        }
        // 只剩 CLI：说明有别的 daemon 在跑（或是个指向已卸载 App 的空壳）
        if let tailscale = CommandRunner.locate("tailscale") {
            let check = CommandRunner.runSync(tailscale, ["version"], timeout: 6)
            if check.ok {
                probe.provider = .remoteCLI
                probe.cli = tailscale
                probe.version = versionText(check.output)
            }
        }
        return probe
    }

    private nonisolated static func versionText(_ output: String) -> String {
        output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    var isAvailable: Bool { provider != .unavailable }
    var canControl: Bool { provider != .unavailable }
    var usesBundledDaemon: Bool { provider == .userspace }

    /// 组网出口的 SOCKS 端口；只有自己拉起的 daemon 才有。
    var outletPort: Int? {
        guard provider == .userspace, daemonRunning, snapshot.isRunning else { return nil }
        return socksPort
    }

    // MARK: - 状态

    func setVisible(_ value: Bool) {
        visible = value
        timer?.invalidate()
        timer = nil
        guard value, provider != .unavailable else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard let cli else { return }
        let result = await command(cli, ["status", "--json"], timeout: 8)
        // 未登录 / 未启动时 CLI 也可能返回非零，但 stdout 仍是完整 JSON。
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let data = text.data(using: .utf8),
              let snapshot = try? TailscaleStatusParser.parse(data) else {
            error = T("读不到 Tailscale 状态")
            return
        }
        self.snapshot = snapshot
        error = nil
        if snapshot.isRunning { loginURL = nil }
        if provider == .userspace, !daemonRunning, snapshot.backendState == "NoState" {
            socksPort = nil
        }
    }

    // MARK: - 控制

    func connect() async {
        guard !busy, let cli else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            if provider == .userspace { try await startDaemon() }
            let result = await command(cli, ["up"], timeout: 20)
            let output = result.output + "\n" + result.error
            if let url = Self.loginURL(in: output) {
                loginURL = url
                NSWorkspace.shared.open(URL(string: url)!)
            } else if !result.ok, result.timedOut == false,
                      !output.localizedCaseInsensitiveContains("already") {
                error = Self.clean(output) ?? T("Tailscale 连接失败")
            }
            await refresh()
            if snapshot.isRunning { loginURL = nil }
        } catch {
            self.error = (error as? ProxyFailure)?.message ?? T("Tailscale 启动失败")
        }
    }

    func disconnect() async {
        guard !busy, let cli else { return }
        busy = true
        defer { busy = false }
        _ = await command(cli, ["down"], timeout: 10)
        await refresh()
    }

    func setExitNode(_ peer: TailscalePeer?) async {
        guard !busy, let cli else { return }
        busy = true
        defer { busy = false }
        let value = peer?.ipv4 ?? ""
        let result = await command(cli, ["set", "--exit-node=\(value)"], timeout: 12)
        if !result.ok {
            // 老版本没有 set 子命令，退回 up。
            _ = await command(cli, ["up", "--exit-node=\(value)"], timeout: 12)
        }
        await refresh()
    }

    func openDownloadPage() {
        NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
    }

    func openTailscaleApp() {
        for url in ["/Applications/Tailscale.app"] where FileManager.default.fileExists(atPath: url) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: url), configuration: NSWorkspace.OpenConfiguration())
            return
        }
        openDownloadPage()
    }

    // MARK: - userspace daemon

    /// 拉起 userspace daemon。等 socket 是异步等——以前在主线程 usleep，最多冻 6 秒。
    private func startDaemon() async throws {
        if let process = daemonProcess, process.isRunning { return }
        guard let daemonPath else { throw ProxyFailure("本机没有 tailscaled") }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let port = Self.freePort() ?? 21080
        let child = Process()
        child.executableURL = URL(fileURLWithPath: daemonPath)
        child.arguments = [
            "--tun=userspace-networking",
            "--socks5-server=127.0.0.1:\(port)",
            "--socket=\(socketURL.path)",
            "--statedir=\(Self.directory.path)",
            "--state=\(stateURL.path)",
            "--no-logs-no-support"
        ]
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        child.standardInput = FileHandle.nullDevice
        try child.run()
        daemonProcess = child
        socksPort = port
        // 等 socket 出现，最多 6 秒；tailscaled 起来慢时上层会看到「正在连接」。
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !FileManager.default.fileExists(atPath: socketURL.path) {
            try? await Task.sleep(for: .milliseconds(120))
            if !child.isRunning { break }
        }
        daemonRunning = child.isRunning && FileManager.default.fileExists(atPath: socketURL.path)
        if !daemonRunning {
            child.terminate()
            daemonProcess = nil
            socksPort = nil
            throw ProxyFailure("tailscaled 启动失败")
        }
    }

    func stopDaemon() {
        guard let process = daemonProcess else { return }
        if process.isRunning { process.terminate() }
        daemonProcess = nil
        daemonRunning = false
        socksPort = nil
    }

    // MARK: - 命令

    private func command(_ cli: String, _ arguments: [String], timeout: TimeInterval) async -> CommandResult {
        var args = arguments
        if provider == .userspace { args.insert("--socket=\(socketURL.path)", at: 0) }
        let path = cli
        return await Task.detached(priority: .utility) {
            CommandRunner.runSync(path, args, timeout: timeout)
        }.value
    }

    private static func loginURL(in text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let value = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>()[]"))
            if value.hasPrefix("https://login.tailscale.com/") || value.hasPrefix("https://headscale") {
                return value
            }
        }
        return nil
    }

    private static func clean(_ text: String) -> String? {
        let value = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("log.tailscale") }
            .suffix(2)
            .joined(separator: " ")
        return value.isEmpty ? nil : value
    }

    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var result = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let name = withUnsafeMutablePointer(to: &result) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard name == 0 else { return nil }
        return Int(UInt16(bigEndian: result.sin_port))
    }
}
