import Darwin
import Foundation

enum FixtureProcess {
    /// NSTask.waitUntilExit 在 run 和 wait 跨异步执行线程时可能卡住 RunLoop。
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let killDeadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < killDeadline { Thread.sleep(forTimeInterval: 0.02) }
    }
}
