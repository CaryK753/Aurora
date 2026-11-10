import AppKit
import SwiftUI

/// 透明窗口的原生承载层也必须透明；SwiftUI clipShape 不会裁剪下方原生玻璃。
final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

@MainActor
enum RoundedWindowSurface {
    static func configure(_ view: NSView, radius: CGFloat) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0
    }
}
