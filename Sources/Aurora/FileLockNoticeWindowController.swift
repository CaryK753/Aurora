import AppKit
import Combine
import SwiftUI

/// 第一次锁定前的说明窗口。菜单栏应用默认不抢焦点，这里先切成普通应用把窗口送到前面。
@MainActor
final class FileLockNoticeWindowController: NSObject, NSWindowDelegate {
    private weak var state: AppState?
    private let window: NSWindow
    private var subscription: AnyCancellable?
    private var restoreAccessory = false

    func windowWillClose(_ notification: Notification) {
        state?.dismissFileLockNotice()
    }

    init(state: AppState) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        self.state = state
        super.init()
        window.delegate = self
        window.title = T("锁定前先看一眼")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.center()

        subscription = state.$showFileLockNotice.removeDuplicates().sink { [weak self] visible in
            guard let self else { return }
            if visible {
                self.window.contentView = NSHostingView(rootView: self.content())
                if NSApp.activationPolicy() != .regular {
                    NSApp.setActivationPolicy(.regular)
                    self.restoreAccessory = true
                }
                self.window.center()
                self.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                self.window.orderOut(nil)
                if self.restoreAccessory {
                    NSApp.setActivationPolicy(.accessory)
                    self.restoreAccessory = false
                }
            }
        }
    }

    private func content() -> FileLockNoticeView {
        FileLockNoticeView(
            onContinue: { [weak self] in self?.state?.confirmFileLockNotice() },
            onCancel: { [weak self] in self?.state?.dismissFileLockNotice() }
        )
    }
}
