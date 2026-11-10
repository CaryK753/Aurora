//  RailDragHandle.swift
//  Aurora — 侧边栏图标的原生拖动会话
//
//  为什么不用 SwiftUI 的 DragGesture：面板是 nonactivating NSPanel，指针一旦离开窗口，
//  SwiftUI 手势就收不到后续事件，表现为「拖不出侧栏、也拖不出主窗口」。
//  原生 NSDraggingSession 由窗口服务器托管，可以拖到屏幕任何位置，还能自己画拖动图。

import AppKit
import SwiftUI

@MainActor
final class RailDragCoordinator {
    /// 拖动中：把屏幕坐标交回 SwiftUI 做实时排序
    var onMove: ((AuroraModule, CGPoint) -> Void)?
    /// 松手：用屏幕坐标判断是「放回侧栏」还是「拖出窗口」
    var onEnd: ((AuroraModule, CGPoint) -> Void)?

    fileprivate var source: RailDragSource?

    func begin(module: AuroraModule, in view: NSView, event: NSEvent, image: NSImage) {
        let item = NSDraggingItem(pasteboardWriter: NSPasteboardItem())
        let center = view.convert(event.locationInWindow, from: nil)
        let size = NSSize(width: 34, height: 30)
        item.setDraggingFrame(
            NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
            contents: image
        )

        let source = RailDragSource(module: module, coordinator: self)
        self.source = source
        view.beginDraggingSession(with: [item], event: event, source: source)
        source.startTracking()
    }

    fileprivate func finish(_ module: AuroraModule, at point: CGPoint) {
        source = nil
        onEnd?(module, point)
    }
}

private final class RailDragSource: NSObject, NSDraggingSource {
    private let module: AuroraModule
    private weak var coordinator: RailDragCoordinator?
    private var timer: Timer?

    init(module: AuroraModule, coordinator: RailDragCoordinator) {
        self.module = module
        self.coordinator = coordinator
    }

    func startTracking() {
        // 拖动会话里没有「移动」回调，自己以 60Hz 读鼠标位置
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            Task { @MainActor in self.coordinator?.onMove?(self.module, point) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        timer?.invalidate()
        timer = nil
        Task { @MainActor in self.coordinator?.finish(self.module, at: screenPoint) }
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

/// 只在按住 ⌘ 时才接管鼠标，平时点击照常交给 SwiftUI 的按钮
struct RailDragHandle: NSViewRepresentable {
    let module: AuroraModule
    let coordinator: RailDragCoordinator

    func makeNSView(context: Context) -> RailDragHandleView {
        let view = RailDragHandleView()
        view.module = module
        view.coordinator = coordinator
        return view
    }

    func updateNSView(_ view: RailDragHandleView, context: Context) {
        view.module = module
        view.coordinator = coordinator
    }
}

final class RailDragHandleView: NSView {
    var module: AuroraModule = .overview
    var coordinator: RailDragCoordinator?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSEvent.modifierFlags.contains(.command) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard NSEvent.modifierFlags.contains(.command), let coordinator else {
            super.mouseDown(with: event)
            return
        }
        coordinator.begin(module: module, in: self, event: event, image: Self.dragImage(for: module))
    }

    /// 拖动图：胶囊底 + 白色图标，和侧栏选中态同一套视觉
    static func dragImage(for module: AuroraModule) -> NSImage {
        let size = NSSize(width: 34, height: 30)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let background = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 10, yRadius: 10)
        NSColor(srgbRed: 0.22, green: 0.62, blue: 0.96, alpha: 1).setFill()
        background.fill()

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let symbolSize = symbol.size
            symbol.draw(in: NSRect(
                x: (size.width - symbolSize.width) / 2,
                y: (size.height - symbolSize.height) / 2,
                width: symbolSize.width,
                height: symbolSize.height
            ))
        }
        return image
    }
}
