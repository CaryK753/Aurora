import AppKit
import SwiftUI

/// 从 SwiftUI 顶栏实际布局取得中心线，避免猜测系统标题栏／安全区高度。
struct WindowHeaderAlignment: NSViewRepresentable {
    var active = true

    func makeNSView(context: Context) -> HeaderAlignmentView { HeaderAlignmentView() }
    func updateNSView(_ view: HeaderAlignmentView, context: Context) {
        view.active = active
        view.scheduleAlignment()
    }
}

final class HeaderAlignmentView: NSView {
    var active = true
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleAlignment()
    }
    override func layout() {
        super.layout()
        scheduleAlignment()
    }
    func scheduleAlignment() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.bounds.height > 0,
                  let panel = self.window as? AuroraPanel else { return }
            panel.headerAlignmentView = self
            panel.alignTrafficLights()
        }
    }
}

extension AuroraPanel {
    func alignTrafficLights() {
        // 全屏标题栏由系统显示／隐藏，保留其原生布局。
        guard allowsMain, styleMask.contains(.titled), !styleMask.contains(.fullScreen),
              let anchor = headerAlignmentView, anchor.window === self, anchor.active,
              let close = standardWindowButton(.closeButton),
              let bar = close.superview?.superview else { return }
        let target = anchor.convert(anchor.bounds, to: nil).midY
        let current = close.convert(close.bounds, to: nil).midY
        let delta = target - current
        guard target.isFinite, abs(delta) > 0.5 else { return }
        // 只移动原生标题栏容器，不替换按钮，保留关闭、最小化及全屏行为。
        var frame = bar.frame
        frame.origin.y += bar.superview?.isFlipped == true ? -delta : delta
        bar.frame = frame
    }
}
