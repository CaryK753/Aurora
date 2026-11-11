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

        var id: String { rawValue }

        var title: String {
            switch self {
            case .panel: return T("显示 / 隐藏主面板")
            case .miniClipboard: return T("唤起 mini 剪切板")
            case .screenshot: return T("区域截图")
            case .recorder: return T("开始 / 停止录屏")
            }
        }

        var symbol: String {
            switch self {
            case .panel: return "menubar.dock.rectangle"
            case .miniClipboard: return "doc.on.clipboard"
            case .screenshot: return "viewfinder"
            case .recorder: return "record.circle"
            }
        }

        var defaultConfig: HotkeyConfig {
            switch self {
            case .panel: return .panel
            case .miniClipboard: return .miniClipboard
            case .screenshot: return .screenshotRegion
            case .recorder: return .recorderToggle
            }
        }

        /// 热键 id：避开 AppDelegate 里 1（面板旧 id）和 2/3（亮度）
        var hotKeyID: UInt32 {
            switch self {
            case .panel: return 1
            case .miniClipboard: return 10
            case .screenshot: return 11
            case .recorder: return 12
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

    private var hotKeyRefs: [Action: EventHotKeyRef?] = [:]
    private var handlerInstalled = false
    /// 录制期间的本地键盘监听
    private var recordMonitor: Any?
    /// 面板热键走旧 id=1 注册时占用的 ref（迁移用，保留兼容）
    private var legacyPanelRef: EventHotKeyRef?

    init() {
        load()
        Self.current = self
    }

    // MARK: - 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
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
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - 查询

    func config(for action: Action) -> HotkeyConfig { configs[action] ?? action.defaultConfig }

    /// 某个组合键是否已被其它动作占用
    func conflict(of config: HotkeyConfig, excluding action: Action) -> Action? {
        configs.first(where: { $0.key != action && $0.value.keyCode == config.keyCode && $0.value.modifiers == config.modifiers })?.key
    }

    // MARK: - 注册

    /// 启动时注册全部；AppDelegate 原来的 registerHotKey() 由这里接管
    func registerAll() {
        installHandlerIfNeeded()
        for action in Action.allCases {
            register(action, config: config(for: action))
        }
    }

    private func register(_ action: Action, config: HotkeyConfig) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4155_5241), id: action.hotKeyID) // 'AURA'
        let status = RegisterEventHotKey(
            config.keyCode,
            config.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        hotKeyRefs[action] = ref
        if status != noErr {
            Debug.log("hotkey \(action.rawValue) register failed: \(status)（多半与系统或其它 App 冲突）")
        }
    }

    private func unregister(_ action: Action) {
        if let ref = hotKeyRefs[action] {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs[action] = nil
    }

    /// 改键：注销旧的 → 持久化 → 注册新的
    func set(_ config: HotkeyConfig?, for action: Action) {
        unregister(action)
        if let config {
            configs[action] = config
        } else {
            configs[action] = action.defaultConfig
        }
        save()
        installHandlerIfNeeded()
        register(action, config: configs[action]!)
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
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
                // 亮度热键（AppDelegate 以同一签名注册的 id 2/3）
                if hotKeyID.id == 2 || hotKeyID.id == 3 {
                    let up = hotKeyID.id == 2
                    Task { @MainActor in
                        HotkeyService.current?.onBrightness?(up)
                    }
                    return noErr
                }
                guard hotKeyID.signature == OSType(0x4155_5241) else { return OSStatus(eventNotHandledErr) }
                let action = Action.allCases.first { $0.hotKeyID == hotKeyID.id }
                guard let action else { return OSStatus(eventNotHandledErr) }
                Task { @MainActor in
                    HotkeyService.current?.onAction?(action)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }

    // MARK: - 录制新组合键

    func startRecording(_ action: Action) {
        endRecording()
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
        recording = nil
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

    private static func namedKeyDisplay(_ keyCode: UInt32) -> String? {
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
