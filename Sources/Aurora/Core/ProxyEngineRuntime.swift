import Foundation
import NetworkProxyKit

@MainActor
final class ProxyEngineRuntime {
    private var process: Process?
    var onUnexpectedExit: (() -> Void)?
    var isRunning: Bool { process?.isRunning == true }

    func start(executable: URL, config: URL, directory: URL, port: Int) async throws {
        guard !isRunning else { throw ProxyFailure("请先关闭当前代理") }
        let checked = await Task.detached(priority: .utility) {
            CommandRunner.runSync(executable.path, ["-t", "-d", directory.path, "-f", config.path], timeout: 30)
        }.value
        // 内核错误可能包含节点密码，不把原始输出放入日志或 UI。
        guard checked.ok else { throw ProxyFailure("内核配置校验失败，请检查节点、DNS 和自定义规则") }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["-d", directory.path, "-f", config.path]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        child.terminationHandler = { [weak self] exited in
            Task { @MainActor in
                guard let self, self.process === exited else { return }
                self.process = nil
                self.onUnexpectedExit?()
            }
        }
        try child.run()
        process = child
        do {
            // 用 HTTP CONNECT 访问不可路由的测试地址无法确认归属；这里发 SOCKS greeting 验证本进程监听。
            var localReady = false
            for _ in 0..<50 {
                guard child.isRunning else { throw ProxyFailure("代理内核启动后退出") }
                if await ProxyLocalProbe.ready(port: port, pid: child.processIdentifier) {
                    localReady = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard localReady else { throw ProxyFailure("代理内核启动超时或端口被占用") }
            let outboundReady = await Task.detached(priority: .utility) {
                CommandRunner.runSync("/usr/bin/curl", [
                    "--silent", "--show-error", "--fail", "--output", "/dev/null",
                    "--max-time", "12", "--proxy", "http://127.0.0.1:\(port)",
                    "https://www.google.com/generate_204"
                ], timeout: 15).ok
            }.value
            guard outboundReady else { throw ProxyFailure("当前节点无法访问 Google，请切换节点后重试") }
        } catch { await stop(); throw error }
    }

    func stop() async {
        guard let child = process else { return }
        process = nil
        child.terminationHandler = nil
        if child.isRunning {
            child.terminate()
            await Task.detached(priority: .utility) {
                let deadline = Date().addingTimeInterval(2)
                while child.isRunning, Date() < deadline { usleep(20_000) }
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                let killDeadline = Date().addingTimeInterval(2)
                while child.isRunning, Date() < killDeadline { usleep(20_000) }
            }.value
        }
    }
}
