import Darwin
import Foundation
import NetworkProxyKit

@main
struct RuntimeCheck {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw ProxyFailure("Missing test engine") }
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ProxyProfileStorage.prepare(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ProxyFailure("Could not reserve test port") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0
            }
        }
        close(descriptor)
        guard bound else { throw ProxyFailure("Could not reserve test port") }
        let port = Int(UInt16(bigEndian: address.sin_port))
        var settings = ProxySettings()
        settings.mode = .direct
        settings.localPort = port
        let config = directory.appendingPathComponent("active.json")
        try ProxyProfileStorage.save(ProxyConfiguration.generate(settings: settings, subscription: ProxySubscription(), mainlandFile: nil), to: config)
        let runtime = ProxyEngineRuntime()
        var crashed = false
        runtime.onUnexpectedExit = { crashed = true }
        try await runtime.start(executable: executable, config: config, directory: directory, port: port)
        assert(runtime.isRunning)
        let conflict = ProxyEngineRuntime()
        do {
            try await conflict.start(executable: executable, config: config, directory: directory, port: port)
            assertionFailure("An occupied port must not pass ownership verification")
        } catch { assert(runtime.isRunning) }
        await runtime.stop()
        assert(!runtime.isRunning && !crashed)
        try await runtime.start(executable: executable, config: config, directory: directory, port: port)
        let processIDs = await Task.detached {
            CommandRunner.runSync("/usr/sbin/lsof", ["-t", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN"], timeout: 3)
        }.value
        guard let pid = Int32(processIDs.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            await runtime.stop()
            throw ProxyFailure("Could not locate test engine")
        }
        kill(pid, SIGTERM)
        for _ in 0..<50 {
            if crashed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        assert(crashed && !runtime.isRunning)
        print("Native runtime startup, SOCKS handshake, port ownership, restart and unexpected-exit checks passed")
    }
}
