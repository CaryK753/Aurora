import Darwin
import Foundation

enum ProxyLocalProbe {
    static func ready(port: Int, pid: pid_t) async -> Bool {
        await Task.detached(priority: .utility) {
            let ownership = CommandRunner.runSync("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"], timeout: 2)
            guard ownership.ok, ownership.output.components(separatedBy: .newlines).contains("n127.0.0.1:\(port)") else { return false }
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { return false }
            var noSignal: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let request: [UInt8] = [5, 1, 0]
            guard request.withUnsafeBytes({ send(descriptor, $0.baseAddress, $0.count, 0) }) == request.count else { return false }
            var response = [UInt8](repeating: 0, count: 2)
            let count = response.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, MSG_WAITALL) }
            return count == 2 && response == [5, 0]
        }.value
    }
}
