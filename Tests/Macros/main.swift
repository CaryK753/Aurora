import AppKit

func check(_ name: String, _ value: @autoclosure () -> Bool) {
    precondition(value(), name)
    print("✓ \(name)")
}
for (name, code): (String, CGKeyCode) in [("后退", 0x21), ("前进", 0x1E)] {
    let down = MacroEvents.key(code, down: true, flags: .maskCommand)!
    let up = MacroEvents.key(code, down: false, flags: .maskCommand)!
    check("\(name)按下与释放配对", down.type == .keyDown && up.type == .keyUp
          && down.getIntegerValueField(.keyboardEventKeycode) == code
          && up.getIntegerValueField(.keyboardEventKeycode) == code)
    check("\(name)按下携带修饰键、抬起释放修饰键", down.flags == .maskCommand && up.flags.isEmpty)
}
let down = NSEvent(cgEvent: MacroEvents.media(16, down: true)!)!
let up = NSEvent(cgEvent: MacroEvents.media(16, down: false)!)!
check("媒体按键类型正确", down.subtype.rawValue == 8 && up.subtype.rawValue == 8)
check("媒体按下编码正确", down.data1 == (16 << 16 | 0xA << 8))
check("媒体抬起使用独立 B00 状态", up.data1 == (16 << 16 | 0xB << 8))
check("媒体按下与抬起事件不同", down.data1 != up.data1)

let defaultDesktop = DockActions.desktopShortcut(in: [:])
check("未自定义显示桌面时使用 Fn-F11", defaultDesktop?.0 == 103 && defaultDesktop?.1 == .maskSecondaryFn)
check("明确禁用显示桌面时不发送事件", DockActions.desktopShortcut(in: ["36": ["enabled": false]]) == nil)
let configured: [String: Any] = ["36": ["enabled": true, "value": ["parameters": [0, 20, CGEventFlags.maskControl.rawValue]]]]
let customDesktop = DockActions.desktopShortcut(in: configured)
check("显示桌面使用用户配置", customDesktop?.0 == 20 && customDesktop?.1 == .maskControl)
