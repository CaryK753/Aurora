//  PointerProbe.swift
//  Aurora — 指针实时读数：只看 Aurora 面板内的事件，不吞事件、不写偏好

import AppKit
import Combine
import SwiftUI

@MainActor
final class PointerProbe: ObservableObject {
    @Published private(set) var dx: Double = 0
    @Published private(set) var dy: Double = 0
    @Published private(set) var scrollY: Double = 0
    @Published private(set) var scrollX: Double = 0
    @Published private(set) var lastButton: String = ""
    @Published private(set) var moveCount: Int = 0
    @Published private(set) var active = false

    private var monitor: Any?
    private var resetTask: Task<Void, Never>?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .otherMouseDown, .leftMouseDown, .rightMouseDown
        ]) { [weak self] event in
            self?.ingest(event)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        resetTask?.cancel()
        resetTask = nil
        active = false
    }

    private func ingest(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            dx = event.deltaX
            dy = event.deltaY
            moveCount += 1
        case .scrollWheel:
            scrollY = event.scrollingDeltaY
            scrollX = event.scrollingDeltaX
        case .otherMouseDown:
            lastButton = TF("按键 %d", event.buttonNumber + 1)
        case .leftMouseDown:
            lastButton = T("左键")
        case .rightMouseDown:
            lastButton = T("右键")
        default:
            break
        }
        active = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                dx = 0
                dy = 0
                scrollX = 0
                scrollY = 0
            }
        }
    }

    func reset() {
        moveCount = 0
        lastButton = ""
        dx = 0
        dy = 0
        scrollY = 0
        scrollX = 0
    }
}
