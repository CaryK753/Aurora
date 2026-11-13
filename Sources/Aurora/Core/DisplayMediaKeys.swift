//  DisplayMediaKeys.swift
//  Aurora — 接管键盘原生亮度键（F1 / F2）
//
//  系统的亮度键走 NX_SYSDEFINED（CGEventType.systemDefined）而不是普通 keyDown，
//  所以 Carbon 热键捕获不到。这里装一个事件 tap，读到亮度键后交给显示器模块处理：
//  · 目标是外接屏 → 吞掉系统事件，用 DDC 调节并显示 HUD
//  · 目标是内建屏 → 放行，交给系统原本的亮度通道
//  按住 ⌥ / ⇧ 时是细调（与系统行为一致，keyFlags 0xB）。

import AppKit

final class DisplayMediaKeys: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// (isUp, isFine) -> 是否已经处理（true = 吞掉这次按键）
    var onStep: ((Bool, Bool) -> Bool)?

    /// 已经吞掉按下，抬起也要一起吞，避免系统补一次原生亮度变化
    private var consumed: Set<Int32> = []

    var isRunning: Bool { tap != nil }

    static var hasAccess: Bool { AXIsProcessTrusted() }

    /// NX_SYSDEFINED：CGEventType 没有对应 case，只能按原始值取
    private static let systemDefinedRaw: UInt32 = 14

    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << Self.systemDefinedRaw)
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: auroraMediaKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        tap = created
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        consumed.removeAll()
    }

    func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }
        guard type.rawValue == Self.systemDefinedRaw,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int32((nsEvent.data1 & 0xFFFF_0000) >> 16)
        let keyFlags = Int32(nsEvent.data1 & 0x0000_FFFF)
        // 0xA = 按下（按住会连发），0xB = 抬起
        let state = (keyFlags & 0xFF00) >> 8
        guard keyCode == 2 || keyCode == 3, state == 0xA || state == 0xB else {
            return Unmanaged.passUnretained(event)
        }

        let isPressed = state == 0xA
        if !isPressed {
            // 按下被我们吞掉过，抬起也要一起吞，否则系统会补一次原生亮度变化
            if consumed.remove(keyCode) != nil { return nil }
            return Unmanaged.passUnretained(event)
        }

        // ⌥ + ⇧ 是系统的细调组合
        let fine = nsEvent.modifierFlags.contains([.option, .shift])
        let handled = onStep?(keyCode == 2, fine) ?? false
        guard handled else { return Unmanaged.passUnretained(event) }
        consumed.insert(keyCode)
        return nil
    }
}

private func auroraMediaKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<DisplayMediaKeys>.fromOpaque(userInfo).takeUnretainedValue()
    return engine.process(type: type, event: event)
}
