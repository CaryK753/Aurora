//  WindowDragHandle.swift
//  Aurora — 通用窗口拖拽把手
//
//  悬浮条 / 气泡这类无边框非激活面板里，SwiftUI 的拖拽手势不可靠，
//  这里用 AppKit 鼠标跟踪直接改窗口 origin。

import AppKit
import SwiftUI

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView { WindowDragNSView() }
    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
}

final class WindowDragNSView: NSView {
    private var startMouse: NSPoint = .zero
    private var startOrigin: NSPoint = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(
            x: startOrigin.x + (now.x - startMouse.x),
            y: startOrigin.y + (now.y - startMouse.y)
        ))
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
    }
}
