import AppKit
import Combine
import SwiftUI

/// 罗技鼠标设置向导窗口：外观与欢迎页一致，检测到设备后自动弹出
///
/// 窗口高度跟着内容走：视图把正文 + 页脚的高度回报上来，
/// 这里保持上边缘不动地改高度，切步骤时不会突然多出一大片空白。
@MainActor
final class LogitechSetupWindowController: NSObject, NSWindowDelegate {
    private weak var state: AppState?
    private(set) var window: NSWindow
    private var subscription: AnyCancellable?

    private let contentWidth: CGFloat = 660

    func windowWillClose(_ notification: Notification) {
        guard let state, state.showLogitechSetup else { return }
        state.dismissLogitechSetup()
    }

    init(state: AppState) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        self.state = state
        super.init()
        window.delegate = self
        window.title = T("罗技鼠标设置")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        installContent()
        window.center()
        subscription = state.$showLogitechSetup.removeDuplicates().sink { [weak self] visible in
            guard let self else { return }
            if visible {
                self.installContent()
                self.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                self.window.orderOut(nil)
            }
        }
    }

    private func installContent() {
        guard let state else { return }
        let root = LogitechSetupView(state: state) { [weak self] height in
            self?.adapt(toContentHeight: height)
        }
        window.contentView = NSHostingView(rootView: root)
    }

    /// 按内容高度调整窗口，保持上边缘位置不动
    private func adapt(toContentHeight height: CGFloat) {
        let target = min(max(height.rounded(), 380), 760)
        guard abs(window.contentLayoutRect.height - target) > 0.5 else { return }
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: contentWidth, height: target))
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x, y: top - window.frame.height))
    }
}
