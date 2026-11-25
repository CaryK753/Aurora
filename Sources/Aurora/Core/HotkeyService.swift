//  HotkeyService.swift
//  Aurora — 全局快捷键：可自定义的 Carbon 热键注册中心
//
//  原来的 ⌥⌘A / ⌃⌥↑↓ 是硬编码注册的；现在把「可配置」的热键统一收到这里，
//  用户在快捷键设置里改键后立刻重注册。亮度热键依赖方向键语义，保持硬编码。

import AppKit
import Carbon.HIToolbox
import Combine

struct HotkeyConfig: Codable, Equatable {
    /// Carbon 虚拟键码（kVK_ANSI_A 之类）
    var keyCode: UInt32
    /// Carbon 修饰键掩码（cmdKey | optionKey …）
    var modifiers: UInt32
    /// 录制时顺手记下的显示文案，界面直接用
    var display: String

    static func captureShortcut(_ code: Int, _ letter: String) -> HotkeyConfig {
        HotkeyConfig(keyCode: UInt32(code), modifiers: UInt32(controlKey | optionKey | cmdKey), display: "⌃⌥⌘" + letter)
    }

    func matches(_ other: HotkeyConfig) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    static let panel = HotkeyConfig(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | optionKey), display: "⌥⌘A")
    /// 早期版本默认 ⇧⌘3，与系统截图热键冲突导致热键收不到，已改为 ⇧⌘V
    static let miniClipboard = HotkeyConfig(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), display: "⇧⌘V")
    /// 旧默认值，用于把存量配置迁移到新默认
    static let legacyMiniClipboard = HotkeyConfig(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey), display: "⇧⌘3")
    static let screenshotRegion = HotkeyConfig(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | optionKey), display: "⌥⌘S")
    static let recorderToggle = HotkeyConfig(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey), display: "⌥⌘R")
}

@MainActor
final class HotkeyService: ObservableObject {
    /// Carbon 回调拿不到 self 指针（Swift 6 并发检查），用 weak 静态引用中转
    static weak var current: HotkeyService?

    enum Action: String, CaseIterable, Identifiable {
        case panel          // 显示 / 隐藏主面板
        case miniClipboard  // mini 剪切板
        case screenshot     // 区域截图
        case recorder       // 开始 / 停止录屏
        case screenshotWindow, screenshotFullscreen, screenshotLong, recorderPause, recorderBar

        var id: String { rawValue }

        var title: String {
            switch self {
            case .panel: return T("显示 / 隐藏主面板")
            case .miniClipboard: return T("唤起 mini 剪切板")
            case .screenshot: return T("区域截图")
            case .recorder: return T("开始 / 停止录屏")
            case .screenshotWindow: return T("窗口截图")
            case .screenshotFullscreen: return T("全屏截图")
            case .screenshotLong: return T("长截图")
            case .recorderPause: return T("暂停 / 继续录屏")
            case .recorderBar: return T("显示 / 隐藏录屏悬浮条")
            }
        }

        var symbol: String {
            switch self {
            case .panel: return "menubar.dock.rectangle"
            case .miniClipboard: return "doc.on.clipboard"
            case .screenshot: return "viewfinder"
            case .recorder: return "record.circle"
            case .screenshotWindow: return "macwindow.on.rectangle"
            case .screenshotFullscreen: return "rectangle.inset.filled"
            case .screenshotLong: return "arrow.down.forward.and.arrow.up.backward"
            case .recorderPause: return "pause.circle"
            case .recorderBar: return "rectangle.3.group.bubble"
            }
        }

        var defaultConfig: HotkeyConfig {
            switch self {
            case .panel: return .panel
            case .miniClipboard: return .miniClipboard
            case .screenshot: return .screenshotRegion
            case .recorder: return .recorderToggle
            case .screenshotWindow: return .captureShortcut(kVK_ANSI_W, "W")
            case .screenshotFullscreen: return .captureShortcut(kVK_ANSI_F, "F")
            case .screenshotLong: return .captureShortcut(kVK_ANSI_L, "L")
            case .recorderPause: return .captureShortcut(kVK_ANSI_P, "P")
            case .recorderBar: return .captureShortcut(kVK_ANSI_B, "B")
            }
        }

        /// 热键 id：避开 AppDelegate 里 1（面板旧 id）和 2/3（亮度）
        var hotKeyID: UInt32 {
            switch self {
            case .panel: return 1
            case .miniClipboard: return 10
            case .screenshot: return 11
            case .recorder: return 12
            case .screenshotWindow: return 13
            case .screenshotFullscreen: return 14
            case .screenshotLong: return 15
            case .recorderPause: return 16
            case .recorderBar: return 17
            }
        }
    }

    static let storageKey = "hotkey.configs"

    @Published private(set) var configs: [Action: HotkeyConfig] = [:]
    /// 正在等待用户按下新组合键的动作
    @Published var recording: Action?

    /// 热键触发回调（AppDelegate 注入）
    var onAction: ((Action) -> Void)?
    /// 亮度热键（⌃⌥↑/⌃⌥↓，id 2/3）回调；亮度键与可配置热键共用这一个处理器，
    /// 不能再单独 InstallEventHandler——同目标的多个处理器「后装先调」，
    /// 后装的处理器返回 noErr 会把事件吞掉，导致所有热键失灵。
    var onBrightness: ((Bool) -> Void)?

    @Published private(set) var registrationErrors: [Action: String] = [:]
    @Published private(set) var editErrors: [Action: String] = [:]
    private var hotKeyRefs: [Action: EventHotKeyRef] = [:]
    private let preferences: UserDefaults
    private var handler: EventHandlerRef?
    /// 录制期间的本地键盘监听
    private var recordMonitor: Any?

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        load()
    }

    deinit {
        if let handler { RemoveEventHandler(handler) }
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
    }

    // MARK: - 持久化

    private func load() {
        guard let data = preferences.data(forKey: Self.storageKey),
              let raw = try? JSONDecoder().decode([String: HotkeyConfig].self, from: data) else {
            configs = Action.allCases.reduce(into: [:]) { $0[$1] = $1.defaultConfig }
            return
        }
        // 旧版默认 ⇧⌘3 和系统截图冲突，用户没改过的话静默迁到 ⇧⌘V
        var migrated = raw
        if migrated[Action.miniClipboard.rawValue] == HotkeyConfig.legacyMiniClipboard {
            migrated[Action.miniClipboard.rawValue] = HotkeyConfig.miniClipboard
        }
        configs = Action.allCases.reduce(into: [:]) { result, action in
            result[action] = migrated[action.rawValue] ?? action.defaultConfig
        }
        if migrated != raw { save() }
    }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: configs.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            preferences.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - 查询

    func config(for action: Action) -> HotkeyConfig { configs[action] ?? action.defaultConfig }

    private func conflictMessage(_ config: HotkeyConfig, excluding action: Action) -> String? {
        if config.modifiers == UInt32(controlKey | optionKey),
           [UInt32(kVK_UpArrow), UInt32(kVK_DownArrow)].contains(config.keyCode) {
            return T("此组合键用于调节亮度")
        }
        if let other = Action.allCases.first(where: {
            $0 != action && hotKeyRefs[$0] != nil && config.matches(self.config(for: $0))
        }) { return TF("与「%@」冲突", other.title) }
        return nil
    }

    func registerAll() {
        installHandlerIfNeeded()
        // 旧用户已经分配的键优先于本版新增的默认组合。
        let custom = Action.allCases.filter { !config(for: $0).matches($0.defaultConfig) }
        for action in custom + Action.allCases.filter({ !custom.contains($0) }) where hotKeyRefs[action] == nil {
            registrationErrors[action] = bind(config(for: action), to: action)
        }
    }

    private func bind(_ config: HotkeyConfig, to action: Action) -> String? {
        if let error = conflictMessage(config, excluding: action) { return error }
        if hotKeyRefs[action] != nil && config.matches(self.config(for: action)) { return nil }

        var ref: EventHotKeyRef?
        let keyID = EventHotKeyID(signature: OSType(0x4155_5241), id: action.hotKeyID)
        let status = RegisterEventHotKey(config.keyCode, config.modifiers, keyID, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else {
            Debug.log("hotkey registration failed for \(action.rawValue): \(status)")
            return TF("无法注册 %@，请尝试其他组合键", config.display)
        }
        if let previous = hotKeyRefs.updateValue(ref, forKey: action) { UnregisterEventHotKey(previous) }
        return nil
    }

    func set(_ config: HotkeyConfig?, for action: Action) {
        let desired = config ?? action.defaultConfig
        installHandlerIfNeeded()
        if let error = bind(desired, to: action) {
            editErrors[action] = error
            return
        }
        configs[action] = desired
        editErrors[action] = nil
        registrationErrors[action] = nil
        save()
        // 改键可能释放了另一个动作原本需要的键位。
        for pending in Action.allCases where registrationErrors[pending] != nil {
            registrationErrors[pending] = bind(self.config(for: pending), to: pending)
        }
    }

    private func receive(_ action: Action) {
        if let recording {
            endRecording()
            set(config(for: action), for: recording)
        } else { onAction?(action) }
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        Self.current = self
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                Debug.log("hotkey event sig=0x\(String(hotKeyID.signature, radix: 16)) id=\(hotKeyID.id)")
                guard hotKeyID.signature == OSType(0x4155_5241) else { return OSStatus(eventNotHandledErr) }
                // 亮度热键（AppDelegate 以同一签名注册的 id 2/3）
                if hotKeyID.id == 2 || hotKeyID.id == 3 {
                    let up = hotKeyID.id == 2
                    Task { @MainActor in
                        guard let service = HotkeyService.current else { return }
                        if let recording = service.recording {
                            service.endRecording()
                            service.editErrors[recording] = T("此组合键用于调节亮度")
                        } else { service.onBrightness?(up) }
                    }
                    return noErr
                }
                let action = Action.allCases.first { $0.hotKeyID == hotKeyID.id }
                guard let action else { return OSStatus(eventNotHandledErr) }
                Task { @MainActor in
                    HotkeyService.current?.receive(action)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handler
        )
    }

    // MARK: - 录制新组合键

    func startRecording(_ action: Action) {
        endRecording()
        editErrors[action] = nil
        recording = action
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording == action else { return event }
            // Esc = 取消录制
            if event.keyCode == UInt16(kVK_Escape) {
                self.endRecording()
                return nil
            }
            // 单击修饰键本身不算组合键
            guard !event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .isSubset(of: [.capsLock]) else { return event }
            let modifiersOnly: NSEvent.ModifierFlags = event.modifierFlags
                .intersection([.command, .option, .control, .shift])
            guard !modifiersOnly.isEmpty else {
                // 无修饰键的组合不许用：会抢走正常打字
                self.endRecording()
                return nil
            }

            let carbonModifiers = Self.carbonModifiers(from: modifiersOnly)
            let display = Self.displayString(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers, fallback: event.charactersIgnoringModifiers)
            let config = HotkeyConfig(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers, display: display)
            self.endRecording()
            self.set(config, for: action)
            return nil
        }
    }

    func endRecording() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        if recording != nil { recording = nil }
    }

    // MARK: - 显示与转换

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    static func displayString(keyCode: UInt32, modifiers: UInt32, fallback: String?) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        if let named = namedKeyDisplay(keyCode) {
            return text + named
        }
        return text + (fallback?.uppercased() ?? "?")
    }

    static func namedKeyDisplay(_ keyCode: UInt32) -> String? {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "␣"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: return nil
        }
    }
}
