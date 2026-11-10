//  ConfirmationAlerts.swift
//  Aurora — 危险操作的统一原生确认框
//
//  面板本身是 popUpMenuWindow 层级，普通 NSAlert 会被压在下面，
//  所以这里的弹窗统一抬高一层，并先把 App 激活。

import AppKit

enum AuroraAlert {
    /// 是否在退出前询问（设置里可关，退出弹窗里的「不再询问」也会关掉它）
    static var confirmBeforeQuit: Bool {
        get { UserDefaults.standard.object(forKey: "settings.confirmBeforeQuit") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "settings.confirmBeforeQuit") }
    }

    @discardableResult
    static func confirm(
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String = T("取消"),
        symbol: String? = nil,
        suppressionTitle: String? = nil,
        suppressionKey: String? = nil
    ) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)
        if let symbol {
            alert.icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }

        var suppression: NSButton?
        if let suppressionTitle {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = suppressionTitle
            suppression = alert.suppressionButton
        }

        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        alert.window.level = NSWindow.Level(rawValue: level + 1)
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed, let key = suppressionKey, suppression?.state == .on {
            UserDefaults.standard.set(false, forKey: key)
        }
        return confirmed
    }

    /// 退出 Aurora：可勾选「不再询问」
    static func confirmQuit() -> Bool {
        guard confirmBeforeQuit else { return true }
        return confirm(
            title: T("退出 Aurora？"),
            message: T("退出后鼠标增强、按应用音量、剪贴板记录和键盘清洁会一并暂停，重新打开即可恢复。"),
            confirmTitle: T("退出"),
            symbol: "power",
            suppressionTitle: T("不再询问"),
            suppressionKey: "settings.confirmBeforeQuit"
        )
    }

    /// 重置所有设置
    static func confirmReset() -> Bool {
        confirm(
            title: T("重置所有设置？"),
            message: T("鼠标、显示、剪贴板、键盘、节能等所有偏好都会恢复默认，剪贴板历史与自定义右键菜单也会被清空。这个操作无法撤销。"),
            confirmTitle: T("重置"),
            symbol: "arrow.counterclockwise"
        )
    }
}
