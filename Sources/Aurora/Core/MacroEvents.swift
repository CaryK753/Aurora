import AppKit

/// 事件构造与投递分离，回归检查不会实际发送按键。
enum MacroEvents {
    static func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) -> CGEvent? {
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down)
        event?.flags = down ? flags : []
        return event
    }

    static func media(_ key: Int32, down: Bool) -> CGEvent? {
        let phase = down ? 0xA : 0xB
        return NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                 modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(phase << 8)),
                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                 subtype: 8, data1: (Int(key) << 16) | (phase << 8), data2: -1)?.cgEvent
    }
}

@MainActor
enum DockActions {
    private typealias Send = @convention(c) (CFString, Int32) -> Void
    private static let framework = dlopen("/System/Library/PrivateFrameworks/CoreDock.framework/CoreDock", RTLD_LAZY)

    static func showDesktop() -> Bool {
        guard let framework, let address = dlsym(framework, "CoreDockSendNotification") else { return false }
        let send = unsafeBitCast(address, to: Send.self)
        send("com.apple.showdesktop.awake" as CFString, 0)
        return true
    }

    /// 兼容符号不可用的系统，读取用户当前快捷键而不是硬编码 F11。
    static func desktopShortcut() -> (CGKeyCode, CGEventFlags)? {
        let keys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        return desktopShortcut(in: keys)
    }

    nonisolated static func desktopShortcut(in keys: [String: Any]?) -> (CGKeyCode, CGEventFlags)? {
        // 系统未写入偏好不等于禁用，默认是 Fn-F11；显式禁用则不发送。
        guard let raw = keys?["36"] else { return (103, .maskSecondaryFn) }
        guard let entry = raw as? [String: Any], entry["enabled"] as? Bool == true,
              let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [NSNumber],
              parameters.count >= 3, parameters[1].intValue >= 0, parameters[1].intValue < 128 else { return nil }
        return (CGKeyCode(parameters[1].uint16Value), CGEventFlags(rawValue: parameters[2].uint64Value))
    }
}
