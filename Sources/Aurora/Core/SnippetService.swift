//  SnippetService.swift
//  Aurora — 自定义短语 / 文本扩展
//
//  监听键盘事件，维护一个输入缓冲：当「缩写 + 触发键」连续打出时，
//  删掉已输入的缩写，再模拟粘贴插入展开内容。听写模式 listenOnly，
//  只观察不拦截，不影响正常打字。

import AppKit
import ApplicationServices
import Combine
import Carbon.HIToolbox

struct Snippet: Codable, Equatable, Identifiable {
    var id: UUID
    var abbr: String
    var text: String
    var enabled: Bool

    init(abbr: String, text: String, enabled: Bool = true) {
        self.id = UUID()
        self.abbr = abbr
        self.text = text
        self.enabled = enabled
    }
}

@MainActor
final class SnippetService: ObservableObject {
    @Published var enabled: Bool {
        didSet { ud.set(enabled, forKey: Keys.enabled); applyEnabled() }
    }
    /// 触发后多长时间内输入才算同一次（防止旧缓冲误触发）
    @Published private(set) var snippets: [Snippet] {
        didSet { persist() }
    }

    @Published private(set) var isActive = false
    private var activationObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?
    private static let marker: Int64 = 0x4155_5253_4E49

    var onToast: ((String, String) -> Void)?

    private let ud = UserDefaults.standard
    private enum Keys {
        static let enabled = "input.snippets.enabled"
        static let list = "input.snippets"
    }
    private static let triggers: Set<String> = [
        " ", "\r", "\n", ".", ",", ";", ":", "!", "?",
        "。", "，", "、", "；", "：", "！", "？",
    ]
    private static let maxLength = 32

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var buffer = ""
    private var lastTypedAt: TimeInterval?
    private var moduleEnabled = true

    init() {
        enabled = ud.object(forKey: Keys.enabled) as? Bool ?? false
        snippets = Self.decode(ud.data(forKey: Keys.list)) ?? Self.builtin()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyEnabled() }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.buffer = "" }
        }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
    }


    func setModuleEnabled(_ value: Bool) {
        moduleEnabled = value
        if !value { stopTap() } else { applyEnabled() }
    }

    func start() {
        applyEnabled()
    }

    // MARK: - 增删

    @discardableResult
    func add(abbr: String, text: String) -> Bool {
        let trimmedAbbr = abbr.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAbbr.isEmpty, !trimmedText.isEmpty else { return false }
        guard trimmedAbbr.count < Self.maxLength, !trimmedAbbr.contains(where: { $0.isWhitespace || Self.triggers.contains(String($0)) }) else {
            onToast?(T("缩写需少于 32 个字符，且不能包含空白或触发标点"), "exclamationmark.triangle")
            return false
        }
        guard !snippets.contains(where: { $0.abbr == trimmedAbbr }) else {
            onToast?(T("缩写已存在"), "exclamationmark.triangle")
            return false
        }
        snippets.append(Snippet(abbr: trimmedAbbr, text: text))
        return true
    }

    func remove(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
    }

    func setEnabled(_ snippet: Snippet, _ value: Bool) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index].enabled = value
    }

    // MARK: - 导入系统文本替换

    /// 系统「键盘 › 文本替换」存在 .GlobalPreferences 的 NSUserDictionaryReplacementItems
    static func systemReplacements() -> [(abbr: String, text: String, enabled: Bool)] {
        let raw = (CFPreferencesCopyAppValue(
            "NSUserDictionaryReplacementItems" as CFString, kCFPreferencesAnyApplication
        ) as? [[String: Any]]) ?? []
        return raw.compactMap { entry in
            guard let abbr = entry["replace"] as? String,
                  let text = entry["with"] as? String else { return nil }
            let on = (entry["on"] as? NSNumber)?.boolValue ?? true
            let trimmedAbbr = abbr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAbbr.isEmpty, !text.isEmpty else { return nil }
            return (trimmedAbbr, text, on)
        }
    }

    /// 导入系统文本替换里还没有的条目，返回（新增, 系统总数）
    @discardableResult
    func importSystemReplacements() -> (added: Int, total: Int) {
        let items = Self.systemReplacements()
        var added = 0
        for item in items where !snippets.contains(where: { $0.abbr == item.abbr }) {
            var snippet = Snippet(abbr: item.abbr, text: item.text, enabled: item.enabled)
            snippet.id = UUID()
            snippets.append(snippet)
            added += 1
        }
        if added == 0, !items.isEmpty {
            onToast?(T("系统里的短语都已经导入过了"), "checkmark.circle")
        } else if added > 0 {
            onToast?(TF("已导入 %d 条系统短语", added), "square.and.arrow.down")
        } else {
            onToast?(T("系统里还没有文本替换短语"), "exclamationmark.triangle")
        }
        return (added, items.count)
    }

    // MARK: - 事件监听

    private func applyEnabled() {
        if enabled, moduleEnabled {
            startTap()
        } else {
            stopTap()
        }
    }

    private func startTap() {
        guard CGPreflightPostEventAccess() else { stopTap(); return }
        guard tap == nil else { isActive = CGEvent.tapIsEnabled(tap: tap!); return }
        let mask = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: auroraSnippetTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Debug.log("snippet: tap create failed (accessibility?)")
            return
        }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        isActive = CGEvent.tapIsEnabled(tap: created)
    }

    private func stopTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        isActive = false
        tapSource = nil
        buffer = ""
    }

    /// 从事件里拿用户敲的字符
    nonisolated private static func typedText(of event: CGEvent) -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        return String(String(decoding: chars.prefix(length), as: UTF16.self))
    }

    fileprivate func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            buffer = ""
            if let tap { CGEvent.tapEnable(tap: tap, enable: true); isActive = CGEvent.tapIsEnabled(tap: tap) }
            return nil
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return nil }
        guard enabled, moduleEnabled, !IsSecureEventInputEnabled() else { buffer = ""; return nil }
        guard type == .keyDown else { buffer = ""; return nil }
        // 带修饰键的是快捷键，别碰
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            buffer = ""
            return nil
        }
        let now = Double(event.timestamp) / 1_000_000_000
        if let lastTypedAt, now - lastTypedAt > 5 { buffer = "" }
        lastTypedAt = now
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if [53, 117, 123, 124, 125, 126, 115, 119, 116, 121, 48].contains(code) { buffer = ""; return nil }
        if code == 51 {
            if !buffer.isEmpty { buffer.removeLast() }
            return nil
        }
        guard let char = Self.typedText(of: event), !char.isEmpty else { buffer = ""; return nil }
        if char.count > 2 { buffer = ""; return nil } // IM 组合串等异常输入，直接跳过

        buffer.append(char)
        if buffer.count > Self.maxLength {
            buffer = String(buffer.suffix(Self.maxLength))
        }
        guard Self.triggers.contains(char), buffer.count > char.count else { return nil }

        // 缓冲里去掉触发键后，看结尾是否命中某个缩写
        let body = String(buffer.dropLast(char.count))
        guard let match = snippets.filter({ $0.enabled && body.hasSuffix($0.abbr) }).max(by: { $0.abbr.count < $1.abbr.count }) else { return nil }
        // 密码框里绝不动作
        guard !inSecureField() else {
            buffer = ""
            return nil
        }

        buffer = ""
        let removed = match.abbr.count + char.count
        let target = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focus = focusedElement()
        Task { @MainActor in
            guard self.enabled, self.moduleEnabled, let target, target == NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let focus, let current = self.focusedElement(), CFEqual(focus, current), !self.inSecureField(), !IsSecureEventInputEnabled(), CGPreflightPostEventAccess() else { return }
            self.expand(match: match, typedLength: removed)
        }
        return nil
    }

    private func expand(match: Snippet, typedLength: Int) {
        var events: [CGEvent] = []
        for _ in 0..<typedLength {
            for down in [true, false] {
                guard let event = MacroEvents.key(51, down: down, flags: []) else { return }
                events.append(event)
            }
        }
        guard let down = MacroEvents.key(0x09, down: true, flags: .maskCommand),
              let up = MacroEvents.key(0x09, down: false, flags: .maskCommand) else { return }
        let clipboard = SnippetPasteboard(NSPasteboard.general)
        guard clipboard.write(match.text) else { return }
        events += [down, up]
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { clipboard.restore() }
    }

    private func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        return (focused as! AXUIElement)
    }

    private func inSecureField() -> Bool {
        guard let element = focusedElement() else { return true }
        var role: CFTypeRef?
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return role == nil || (role as? String) == "AXSecureTextField" || (subrole as? String) == "AXSecureTextField"
    }

    // MARK: - 持久化

    private nonisolated static func decode(_ data: Data?) -> [Snippet]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([Snippet].self, from: data)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snippets) {
            ud.set(data, forKey: Keys.list)
        }
    }

    /// 第一次使用的示例短语
    private nonisolated static func builtin() -> [Snippet] {
        [
            Snippet(abbr: "email", text: "you@example.com", enabled: false),
            Snippet(abbr: "addr", text: "上海市浦东新区", enabled: false),
        ]
    }
}

private func auroraSnippetTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return nil }
    let service = Unmanaged<SnippetService>.fromOpaque(userInfo).takeUnretainedValue()
    return MainActor.assumeIsolated {
        service.process(type: type, event: event)
    }
}
