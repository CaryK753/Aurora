import AppKit
import Combine
import SwiftUI

/// 「新功能」窗口：每个版本只在更新后的第一次启动时弹一次
@MainActor
final class WhatsNewWindowController: NSObject, NSWindowDelegate {
    private weak var state: AppState?
    private let window: NSWindow
    private var subscription: AnyCancellable?

    func windowWillClose(_ notification: Notification) {
        ReleaseNotesStore.markSeen()
        Debug.log("whatsnew: closed, marked \(ReleaseNotesStore.currentVersion) as seen")
        state?.showWhatsNew = false
    }

    init(state: AppState) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 660),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        self.state = state
        super.init()
        window.delegate = self
        window.title = T("新功能")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.center()

        subscription = state.$showWhatsNew.removeDuplicates().sink { [weak self] visible in
            guard let self else { return }
            if visible {
                // 重新构建内容：语言 / 外观可能在上次看过之后改过
                self.window.contentView = NSHostingView(rootView: self.content())
                self.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                Debug.log("whatsnew: showing \(ReleaseNotesStore.currentVersion) window=\(self.window.frame) content=\(self.window.contentLayoutRect)")
            } else {
                self.window.orderOut(nil)
            }
        }
    }

    private func content() -> WhatsNewView {
        WhatsNewView(
            notes: ReleaseNotesStore.notes(),
            version: ReleaseNotesStore.currentVersion,
            onContinue: { [weak self] in
                ReleaseNotesStore.markSeen()
                self?.state?.showWhatsNew = false
                self?.window.orderOut(nil)
            },
            onOpenReleasePage: {
                NSWorkspace.shared.open(UpdateService.releasesPage)
            }
        )
    }
}
