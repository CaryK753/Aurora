import Foundation

final class LogitechReportRouter {
    private let lock = NSLock()
    private var routes: [UInt8: ([UInt8]) -> Void] = [:]
    func add(_ index: UInt8, handler: @escaping ([UInt8]) -> Void) {
        lock.lock(); routes[index] = handler; lock.unlock()
    }
    func receive(_ report: [UInt8]) {
        guard report.count >= 4 else { return }
        lock.lock()
        let handler = routes[report[1]] ?? ((report[1] == 0 || report[1] == 0xFF) ? routes[0xFF] : nil)
        lock.unlock()
        handler?(report)
    }
}
