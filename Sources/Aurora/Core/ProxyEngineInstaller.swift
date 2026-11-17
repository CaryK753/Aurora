import CryptoKit
import Foundation
import NetworkProxyKit

enum ProxyEngineInstaller {
    static func install(in directory: URL) async throws -> String {
        #if arch(arm64)
        let platform = "arm64"
        #else
        let platform = "amd64-compatible"
        #endif
        guard let digest = ProxyEngineRelease.checksums[platform] else {
            throw ProxyFailure("未找到可校验的 macOS 代理内核")
        }
        let archive = try await ProxyHTTPClient.fetch(ProxyEngineRelease.downloadURL(platform: platform), limit: 100 * 1024 * 1024, timeout: 300)
        let actual = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        guard actual == digest else { throw ProxyFailure("代理内核校验失败") }
        return try await Task.detached(priority: .utility) {
            try ProxyProfileStorage.prepare(directory)
            let temporary = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try ProxyProfileStorage.prepare(temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let compressed = temporary.appendingPathComponent("mihomo.gz")
            try ProxyProfileStorage.save(archive, to: compressed)
            let result = CommandRunner.runSync("/usr/bin/gzip", ["-d", compressed.path], timeout: 60)
            guard result.ok else { throw ProxyFailure("代理内核解压失败") }
            let executable = temporary.appendingPathComponent("mihomo")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let version = CommandRunner.runSync(executable.path, ["-v"], timeout: 10)
            guard version.ok, version.output.lowercased().contains("mihomo") else { throw ProxyFailure("代理内核无法运行") }
            let destination = directory.appendingPathComponent("mihomo")
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: executable)
            } else { try FileManager.default.moveItem(at: executable, to: destination) }
            return ProxyEngineRelease.version
        }.value
    }
}
