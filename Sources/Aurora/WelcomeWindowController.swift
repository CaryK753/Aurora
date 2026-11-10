import AppKit
import Combine
import SwiftUI

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private weak var state: AppState?
    private let window: NSWindow
    private var subscription: AnyCancellable?

    func windowWillClose(_ notification: Notification) { state?.showWelcome = false }

    init(state: AppState) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        self.state = state
        super.init()
        window.delegate = self
        window.title = T("欢迎使用 Aurora")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WelcomeView(state: state))
        window.center()
        subscription = state.$showWelcome.removeDuplicates().sink { [weak self] visible in
            guard let self else { return }
            if visible {
                self.window.contentView = NSHostingView(rootView: WelcomeView(state: state))
                self.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else { self.window.orderOut(nil) }
        }
    }
}
