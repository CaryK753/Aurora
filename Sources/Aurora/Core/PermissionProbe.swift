import Foundation

/// 子进程不初始化 AppState，不创建菜单栏、事件 tap 或新的授权请求。
enum PermissionProbe {
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { T("权限复查未完成，请重试；已保留当前检测结果") }
    }

    static func run(executable: URL) async -> Result<PermissionSnapshot, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let output = Pipe()
                process.executableURL = executable
                process.arguments = ["--permission-probe"]
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do { try process.run() }
                catch { continuation.resume(returning: .failure(error)); return }
                let deadline = Date().addingTimeInterval(4)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.04) }
                guard !process.isRunning else {
                    process.terminate()
                    continuation.resume(returning: .failure(Failure.unavailable))
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus == 0,
                      let snapshot = try? JSONDecoder().decode(PermissionSnapshot.self, from: data) else {
                    continuation.resume(returning: .failure(Failure.unavailable))
                    return
                }
                continuation.resume(returning: .success(snapshot))
            }
        }
    }
}
