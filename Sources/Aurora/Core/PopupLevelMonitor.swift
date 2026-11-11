//  PopupLevelMonitor.swift
//  Aurora — 原生弹窗层级统一治理
//
//  主面板在浮动模式是 popUpMenuWindow 层级，普通 SwiftUI popover / sheet
//  会以默认层级创建窗口，可能被压在面板下面（固定模式下问题相反地也存在：
//  弹窗挂在 normal 面板上，但用户切走后再回来可能被其它窗口遮挡）。
//  这里统一监听：
//  · NSPopover 弹出 → 把它的宿主窗口抬到 popUpMenuWindow + 1
//  · 任意窗口变 key 且是 sheet 子窗口 / popover 窗口 → 同样抬高
//  这样无论主面板处于浮动还是固定模式，原生弹窗都保证高于主窗口。

import AppKit

@MainActor
enum PopupLevelMonitor {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        let center = NotificationCenter.default
        center.addObserver(forName: NSPopover.didShowNotification, object: nil, queue: .main) { note in
            Task { @MainActor in
                guard let popover = note.object as? NSPopover else { return }
                raise(popover.contentViewController?.view.window)
            }
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            Task { @MainActor in
                guard let window = note.object as? NSWindow, needsRaise(window) else { return }
                raise(window)
            }
        }
    }

    /// 只处理 sheet 子窗口与 popover 宿主窗口，别把自家面板等普通窗口卷进来
    private static func needsRaise(_ window: NSWindow) -> Bool {
        if window.sheetParent != nil { return true }
        return NSStringFromClass(type(of: window)).contains("Popover")
    }

    private static func raise(_ window: NSWindow?) {
        guard let window else { return }
        let target = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        if window.level.rawValue < target.rawValue {
            window.level = target
        }
        // 全屏时面板照样能用，弹窗也要跟得上
        window.collectionBehavior.formUnion([.fullScreenAuxiliary])
    }
}
