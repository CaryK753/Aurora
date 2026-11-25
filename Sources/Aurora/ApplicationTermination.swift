import AppKit

/// 菜单退出先完成异步清理，再进入 AppKit 退出流程；系统发起的退出沿用 terminateLater。
@MainActor
final class ApplicationTermination {
    private var preparing = false
    private var approved = false
    private var awaitingSystemReply = false
    private let prepare: () async throws -> Void
    private let reportError: (Error) -> Void

    init(prepare: @escaping () async throws -> Void, reportError: @escaping (Error) -> Void) {
        self.prepare = prepare
        self.reportError = reportError
    }

    func systemRequest() -> NSApplication.TerminateReply {
        if approved { return .terminateNow }
        awaitingSystemReply = true
        begin()
        return .terminateLater
    }

    func begin() {
        guard !preparing else { return }
        preparing = true
        Task { @MainActor in
            do {
                try await prepare()
                approved = true
                if awaitingSystemReply { NSApp.reply(toApplicationShouldTerminate: true) }
                else { NSApp.terminate(nil) }
            } catch {
                preparing = false
                if awaitingSystemReply {
                    awaitingSystemReply = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                }
                reportError(error)
            }
        }
    }
}
