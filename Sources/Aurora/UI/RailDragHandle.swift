//  RailDragHandle.swift
//  Aurora — 侧边栏图标的 ⌘ + 拖动排序（窗口级事件监听）
//
//  为什么不用 SwiftUI 的 DragGesture：面板是 nonactivating NSPanel，指针一旦离开窗口，
//  SwiftUI 手势就收不到后续事件。也不再走 NSDraggingSession + NSViewRepresentable：
//  在非激活面板上 hitTest 与拖动会话的触发都不可靠（表现为「按住 ⌘ 拖动毫无反应」）。
//  现在直接在窗口层装本地事件监听：⌘ 按下且落点在侧栏图标上就接管这次按下，
//  后续 mouseDragged / mouseUp 一并拦截，坐标统一用屏幕坐标（NSEvent.mouseLocation）。

import AppKit
import SwiftUI

@MainActor
final class RailDragCoordinator {
    /// 判断屏幕坐标落在哪个侧栏图标上（RootView 用 railFrames 提供）
    var hitModule: ((CGPoint) -> AuroraModule?)?
    /// 拖动中：把屏幕坐标交回 SwiftUI 做实时排序
    var onMove: ((AuroraModule, CGPoint) -> Void)?
    /// 松手：用屏幕坐标判断是「放回侧栏」还是「拖出窗口」
    var onEnd: ((AuroraModule, CGPoint) -> Void)?
    /// 拖动是否进行中（RootView 据此调暗原图标、显示提示）
    private(set) var dragging: AuroraModule?

    private var monitor: Any?

    /// ⌘ + 按下且命中侧栏图标 → 接管拖动，返回 true 表示事件已被消费
    func mouseDown(at screenPoint: CGPoint) -> Bool {
        guard dragging == nil, NSEvent.modifierFlags.contains(.command),
              let module = hitModule?(screenPoint) else { return false }
        dragging = module
        onMove?(module, screenPoint)
        installTrackingMonitor()
        return true
    }

    private func installTrackingMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            let point = NSEvent.mouseLocation
            if event.type == .leftMouseUp {
                self.endDrag(at: point)
                return nil
            }
            self.onMove?(self.dragging ?? .overview, point)
            return nil
        }
    }

    private func endDrag(at screenPoint: CGPoint) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let module = dragging
        dragging = nil
        if let module { onEnd?(module, screenPoint) }
    }
}
