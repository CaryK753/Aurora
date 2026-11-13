//  CaretLocator.swift
//  Aurora — 「用户正在输入的位置」：读前台 App 聚焦控件的文本插入点，
//  用来把 mini 剪切板贴在光标旁边弹出，而不是永远出现在屏幕中上。
//
//  参考 Maccy（reference/maccy/Maccy/PopupPosition.swift）：
//  · 弹窗按锚点定位（cursor / window / center / lastPosition），
//  · 定位后用 constrained() 夹在当前屏幕的 visibleFrame 里，避免溢到隔壁显示器。
//  Maccy 的锚点默认是鼠标；这里把锚点换成文本插入点（AXBoundsForRange），
//  拿不到时依次退回聚焦控件矩形、鼠标位置（即原来的中上弹出）。

import AppKit
import ApplicationServices

/// 一次探测的结果。矩形都是 AppKit 屏幕坐标（原点在主屏左下，y 向上）。
struct CaretProbe: Equatable {
    /// 文本插入点（已撑成一行的高度，方便当锚点）
    var caret: NSRect?
    /// 聚焦控件本身的矩形（插入点读不到时用它）
    var field: NSRect?
    /// 前台 App 的聚焦窗口（AX 完全问不出来时用它兜底）
    var window: NSRect?
    var isSecure: Bool = false
    /// 聚焦控件的 role（调试线索）
    var role: String = ""
    /// 调试线索：为什么没拿到插入点
    var note: String = ""

    /// 是不是个像样的文本输入控件
    var isTextInput: Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXTextView"].contains(role)
    }
}

enum CaretLocator {
    /// 探测当前前台 App 的输入位置。调用方应在弹出面板**之前**调用，
    /// 否则面板自己变成 key window、焦点元素就换人了。
    static func probe() -> CaretProbe {
        var result = CaretProbe()
        guard AXIsProcessTrusted() else {
            result.note = "no-accessibility"
            return result
        }

        var (element, notes) = focusedElement()
        // 焦点刚切过去 / Electron 的 AX 树刚被我们打开：稍等一下再问一次
        if element == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            let retry = focusedElement()
            element = retry.0
            notes += retry.1.isEmpty ? [] : ["retry:\(retry.1)"]
        }
        guard let element else {
            result.note = "no-focused-element[\(notes.joined(separator: " "))]"
            // AX 一点都给不出来（Electron / 远程桌面常见）：至少用聚焦窗口兜个底
            result.window = focusedWindowRect()
            return result
        }
        // 有的 App（Electron / 远程桌面）AX 调用会卡住，给个短超时
        AXUIElementSetMessagingTimeout(element, 0.6)

        if let subrole = stringValue(element, kAXSubroleAttribute as CFString),
           subrole == "AXSecureTextField" {
            result.isSecure = true
        }
        result.role = stringValue(element, kAXRoleAttribute as CFString) ?? ""

        result.field = elementFrame(element)

        // 1) 标准路径：AXBoundsForRange
        if let range = selectedRange(element),
           let rect = caretBounds(element, range: range),
           let line = lineRect(rect),
           plausible(line, field: result.field) {
            result.caret = line
        } else if let rect = caretBoundsViaTextMarker(element),
                  let line = lineRect(rect),
                  plausible(line, field: result.field) {
            // 2) Chromium / WebKit：AXBoundsForRange 给 0×0，改问 text marker
            result.caret = line
            result.note = "viaTextMarker"
        } else if result.field != nil {
            result.note = "no-caret"
        } else {
            result.note = "no-focused-input"
        }

        return result
    }

    /// 插入点要落在控件附近、且细得像一根光标；否则多半是网页 / 编辑器报了
    /// 个假矩形（Chromium 的 AXBoundsForRange 就爱回 (0, 屏高, 0, 0)）
    private static func plausible(_ caret: NSRect, field: NSRect?) -> Bool {
        guard let field else { return true }
        let allowed = field.insetBy(dx: -40, dy: -40)
        guard caret.width <= 12, caret.height <= max(field.height, 80) else { return false }
        return allowed.contains(NSPoint(x: caret.midX, y: caret.midY))
    }

    /// Chromium / WebKit 不走 AXBoundsForRange（会返回 0×0 的假矩形），
    /// 改用 text marker：AXSelectedTextMarkerRange + AXBoundsForTextMarkerRange
    private static func caretBoundsViaTextMarker(_ element: AXUIElement) -> CGRect? {
        var marker: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &marker
        ) == .success, let marker else { return nil }

        var raw: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, marker, &raw
        )
        guard err == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgRect, &rect),
              rect.width.isFinite, rect.height.isFinite, rect.height > 0 else { return nil }
        return rect
    }

    /// 前台 App 的聚焦窗口矩形：先问 AX，AX 一点都给不出来时退回 CGWindowList
    static func focusedWindowRect() -> NSRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.6)
        var app: AXUIElement?
        var appRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
           let appRef, CFGetTypeID(appRef) == AXUIElementGetTypeID() {
            app = unsafeBitCast(appRef, to: AXUIElement.self)
        } else if let front = NSWorkspace.shared.frontmostApplication {
            app = AXUIElementCreateApplication(front.processIdentifier)
        }
        if let app {
            AXUIElementSetMessagingTimeout(app, 0.6)
            if let window = elementValue(app, kAXFocusedWindowAttribute as CFString),
               let rect = elementFrame(window) {
                return rect
            }
        }
        return frontWindowRect()
    }

    /// CGWindowList 里前台 App 最前面的普通窗口（不需要 AX）
    private static func frontWindowRect() -> NSRect? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == front.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 120, rect.height > 80 else { continue }
            return appKitRect(fromAX: rect)
        }
        return nil
    }

    // MARK: - AX 读取

    /// 启动日志用：辅助功能授权 + AX 端口是否真的可用
    static func availability() -> String {
        let trusted = AXIsProcessTrusted()
        let myself = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(myself, 0.3)
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(myself, kAXRoleAttribute as CFString, &raw)
        if err == .success {
            return "trusted=\(trusted) ax=ok(\(raw as? String ?? "-"))"
        }
        return "trusted=\(trusted) ax=error(\(err.rawValue))"
    }

    private static func errorCode(_ element: AXUIElement, _ attribute: CFString) -> String {
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &raw)
        return err == .success ? "0（有值）" : "\(err.rawValue)"
    }

    private static func describe(_ element: AXUIElement) -> String {
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        var subroleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        return "role=\((roleRef as? String) ?? "-") subrole=\((subroleRef as? String) ?? "-")"
    }

    /// 逐层打印 AX 查询的错误码（`Aurora --caret-probe`），排查「为什么没贴在光标上」
    static func diagnose() -> [String] {
        var lines: [String] = []
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知"
        lines.append("前台 App：\(front)")
        lines.append("辅助功能：\(AXIsProcessTrusted() ? "已授权" : "未授权")")

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)

        var sysFocus: CFTypeRef?
        let sysFocusErr = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &sysFocus)
        lines.append("systemWide kAXFocusedUIElement → \(sysFocusErr.rawValue)")
        if sysFocusErr == .success, let sysFocus, CFGetTypeID(sysFocus) == AXUIElementGetTypeID() {
            lines.append("systemWide 聚焦元素 → \(describe(unsafeBitCast(sysFocus, to: AXUIElement.self)))")
        }

        // 自己这个进程的 AX 端口通不通（排除「整个 AX 都不可用」）
        let myself = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(myself, 2)
        lines.append("self kAXRole → \(errorCode(myself, kAXRoleAttribute as CFString))")
        lines.append("self kAXWindows → \(errorCode(myself, kAXWindowsAttribute as CFString))")

        var appRef: CFTypeRef?
        let appErr = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef)
        lines.append("kAXFocusedApplication → \(appErr.rawValue)")

        if appErr == .success, let appRef, CFGetTypeID(appRef) == AXUIElementGetTypeID() {
            let app = unsafeBitCast(appRef, to: AXUIElement.self)
            var mainRole: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(app, kAXTitleAttribute as CFString, &mainRole)
            lines.append("App 标题 → \((mainRole as? String) ?? "-")")

            var focusRef: CFTypeRef?
            let focusErr = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusRef)
            lines.append("kAXFocusedUIElement → \(focusErr.rawValue)")

            if focusErr == .success, let focusRef, CFGetTypeID(focusRef) == AXUIElementGetTypeID() {
                let element = unsafeBitCast(focusRef, to: AXUIElement.self)
                var roleRef: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
                var subroleRef: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
                lines.append("聚焦控件：role=\((roleRef as? String) ?? "-") subrole=\((subroleRef as? String) ?? "-")")

                var rangeRef: CFTypeRef?
                let rangeErr = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
                lines.append("kAXSelectedTextRange → \(rangeErr.rawValue)")

                if rangeErr == .success, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() {
                    var range = CFRange(location: 0, length: 0)
                    let ok = AXValueGetValue(unsafeBitCast(rangeRef, to: AXValue.self), .cfRange, &range)
                    lines.append("range 解析=\(ok ? "成功" : "失败") location=\(range.location) length=\(range.length)")

                    var probeRange = CFRange(location: range.location, length: 0)
                    if let axRange = AXValueCreate(.cfRange, &probeRange) {
                        var boundsRef: CFTypeRef?
                        let boundsErr = AXUIElementCopyParameterizedAttributeValue(
                            element,
                            kAXBoundsForRangeParameterizedAttribute as CFString,
                            axRange,
                            &boundsRef
                        )
                        lines.append("kAXBoundsForRange → \(boundsErr.rawValue)")
                        if boundsErr == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() {
                            var rect = CGRect.zero
                            let ok2 = AXValueGetValue(unsafeBitCast(boundsRef, to: AXValue.self), .cgRect, &rect)
                            lines.append("bounds 解析=\(ok2 ? "成功" : "失败") AX 矩形=\(rect)")
                            lines.append("换算成 AppKit=\(lineRect(rect).map { "\($0)" } ?? "屏外")")
                        }
                    }
                }
            }
        }

        let probe = probe()
        lines.append("probe：caret=\(String(describing: probe.caret)) field=\(String(describing: probe.field)) note=\(probe.note.isEmpty ? "-" : probe.note)")
        return lines
    }

    /// 依次试：系统级 focusedApplication → 前台进程 → 聚焦窗口 → 系统级 focusedUIElement
    /// 返回元素和「哪一步失败了」的错误码，方便日志排查。
    private static func focusedElement() -> (AXUIElement?, [String]) {
        var notes: [String] = []
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.6)

        var appElement: AXUIElement?
        var raw: CFTypeRef?
        let appErr = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &raw)
        if appErr == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
            appElement = unsafeBitCast(raw, to: AXUIElement.self)
        } else {
            notes.append("focusedApp=\(appErr.rawValue)")
        }

        // 某些系统版本 focusedApplication 会失败，改按前台进程 PID 建元素
        if appElement == nil, let front = NSWorkspace.shared.frontmostApplication {
            let created = AXUIElementCreateApplication(front.processIdentifier)
            appElement = created
            notes.append("pid=\(front.bundleIdentifier ?? "?")")
        }

        if let appElement {
            AXUIElementSetMessagingTimeout(appElement, 0.6)
            enableAccessibilityTree(appElement)

            if let focused = elementValue(appElement, kAXFocusedUIElementAttribute as CFString) {
                return (focused, notes)
            }
            notes.append("focusedUI=nil")

            // 退一步：聚焦窗口里的聚焦元素（编辑器 / 网页常用）
            var windowRef: CFTypeRef?
            let winErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
            if winErr == .success, let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() {
                let window = unsafeBitCast(windowRef, to: AXUIElement.self)
                if let focused = elementValue(window, kAXFocusedUIElementAttribute as CFString) {
                    notes.append("viaWindow")
                    return (focused, notes)
                }
                notes.append("windowUI=nil")
            } else {
                notes.append("focusedWindow=\(winErr.rawValue)")
            }
        }

        if let focused = elementValue(system, kAXFocusedUIElementAttribute as CFString) {
            notes.append("viaSystem")
            return (focused, notes)
        }
        notes.append("systemUI=nil")
        return (nil, notes)
    }

    /// Chromium / Electron（Chrome、Obsidian、Slack、Discord…）默认关着 AX 树，
    /// 要客户端显式打这两个开关才会把焦点元素报出来
    private static func enableAccessibilityTree(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private static func value(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw
    }

    private static func elementValue(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let raw = value(element, attribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private static func stringValue(_ element: AXUIElement, _ attribute: CFString) -> String? {
        guard let raw = value(element, attribute) else { return nil }
        return raw as? String
    }

    /// 选区的 CFRange。有选中内容时取起点：粘贴要替换的就是这段。
    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let raw = value(element, kAXSelectedTextRangeAttribute as CFString),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return CFRange(location: range.location, length: 0)
    }

    /// AXBoundsForRange：光标（或选区起点）的屏幕矩形，AX 坐标（左上原点、y 向下）
    private static func caretBounds(_ element: AXUIElement, range: CFRange) -> CGRect? {
        var range = range
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &raw
        ) == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgRect, &rect) else { return nil }
        return rect
    }

    private static func elementFrame(_ element: AXUIElement) -> NSRect? {
        guard let posRaw = value(element, kAXPositionAttribute as CFString),
              let sizeRaw = value(element, kAXSizeAttribute as CFString),
              CFGetTypeID(posRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(posRaw, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(sizeRaw, to: AXValue.self), .cgSize, &size),
              size.width > 1, size.height > 1 else { return nil }

        let rect = appKitRect(fromAX: CGRect(origin: point, size: size))
        return onScreen(rect) ? rect : nil
    }

    // MARK: - 坐标换算

    /// AX 全局坐标：原点在主屏左上角、y 向下；AppKit：原点在主屏左下角、y 向上。
    static func appKitRect(fromAX rect: CGRect) -> NSRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 插入点常常是 0 高（有的 App 给 0×0）：撑成一行再当锚点。
    /// AX 里 y 向下，加高就是往下长——正好是这一行。
    private static func lineRect(_ axRect: CGRect) -> NSRect? {
        guard axRect.minX.isFinite, axRect.minY.isFinite,
              axRect.width.isFinite, axRect.height.isFinite else { return nil }
        var rect = axRect
        if rect.height < 2 { rect.size.height = 14 }
        if rect.width < 2 { rect.size.width = 4 }
        let converted = appKitRect(fromAX: rect)
        guard onScreen(converted) else { return nil }
        return converted
    }

    private static func onScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { $0.frame.insetBy(dx: -8, dy: -8).intersects(rect) }
    }
}

// MARK: - 面板摆放

enum MiniClipboardPlacement {
    enum Anchor: String {
        case caret      // 文本插入点
        case field      // 聚焦控件
        case window     // 前台 App 的窗口（AX 给不出输入框时）
        case mouse      // 兜底：屏幕中上（老行为）
    }

    /// 面板与锚点之间的空隙
    static let gap: CGFloat = 10
    /// 与屏幕可见区的最小留白
    static let margin: CGFloat = 10

    static func resolve(size: CGSize, probe: CaretProbe, mouse: NSPoint) -> (frame: NSRect, anchor: Anchor) {
        // 输入框里：优先贴在光标上方（搜索框在面板底部，正好贴着光标），
        // 上方放不下（光标靠近屏幕顶部）才翻到下方。
        if let caret = probe.caret, let frame = grounded(size: size, anchor: caret, preferAbove: true) {
            return (frame, .caret)
        }
        // 控件里但读不到插入点（自绘输入框 / 安全输入）：整块控件当锚点，落在它下方。
        // 但控件占了大半屏（浏览器 / 编辑器的整个内容区）时没意义，宁可退回屏幕中上。
        if let field = probe.field, let screen = screen(hitBy: field) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if field.width * field.height < visible.width * visible.height * 0.55,
               let frame = grounded(size: size, anchor: field, preferAbove: false) {
                return (frame, .field)
            }
        }
        // AX 连输入框都不给：至少贴着前台窗口的底部（聊天输入框一般在那儿）
        if let window = probe.window, let screen = screen(hitBy: window) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let x = clamp(window.midX - size.width / 2, visible.minX + margin, visible.maxX - size.width - margin)
            let y = clamp(window.minY + 12, visible.minY + margin, visible.maxY - size.height - margin)
            return (NSRect(x: x, y: y, width: size.width, height: size.height), .window)
        }

        return (spotlight(size: size, mouse: mouse), .mouse)
    }

    /// 贴锚点摆放，并夹进锚点所在屏幕的 visibleFrame（Maccy 的 constrained）
    private static func grounded(size: CGSize, anchor: NSRect, preferAbove: Bool) -> NSRect? {
        guard let screen = screen(hitBy: anchor) ?? NSScreen.main else { return nil }
        let visible = screen.visibleFrame

        let above = NSRect(x: anchor.minX, y: anchor.maxY + gap, width: size.width, height: size.height)
        let below = NSRect(x: anchor.minX, y: anchor.minY - gap - size.height, width: size.width, height: size.height)
        let candidates = preferAbove ? [above, below] : [below, above]

        var frame = candidates.first { fits($0, in: visible) } ?? candidates[0]
        frame.origin.x = clamp(frame.minX, visible.minX + margin, visible.maxX - size.width - margin)
        frame.origin.y = clamp(frame.minY, visible.minY + margin, visible.maxY - size.height - margin)
        return frame
    }

    /// 老行为：鼠标所在屏幕、水平居中、偏上 12%（Spotlight 位置）
    private static func spotlight(size: CGSize, mouse: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - visible.height * 0.12,
            width: size.width,
            height: size.height
        )
    }

    /// 锚点落在哪块屏上（取交叠面积最大的那块）
    private static func screen(hitBy rect: NSRect) -> NSScreen? {
        let probe = rect.insetBy(dx: -1, dy: -1)
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for candidate in NSScreen.screens {
            let overlap: NSRect = candidate.frame.intersection(probe)
            if overlap.isNull { continue }
            let area: CGFloat = overlap.width * overlap.height
            if area <= 0 { continue }
            if area > bestArea {
                bestArea = area
                best = candidate
            }
        }
        return best
    }

    private static func fits(_ rect: NSRect, in visible: NSRect) -> Bool {
        rect.minY >= visible.minY + margin && rect.maxY <= visible.maxY - margin
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return min(max(value, lower), upper)
    }
}
