//  InputMethodService.swift
//  Aurora — 输入法增强：状态指示器、按 App / 网站自动切换
//
//  切换输入法走 Carbon 的 TIS API（不需要额外权限）；
//  网站规则靠辅助功能读浏览器地址栏的 URL，指示器贴着光标显示当前输入法。

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// MARK: - 输入源模型

struct IMSource: Identifiable, Equatable {
    /// kTISPropertyInputSourceID，如 com.apple.inputmethod.SCIM.ITABC
    let id: String
    let name: String
    let isChinese: Bool

    /// 指示器上的短标签
    var shortLabel: String {
        if isChinese {
            if name.contains("五笔") || id.lowercased().contains("wubi") { return "五" }
            if name.contains("拼音") || id.lowercased().contains("pinyin") { return "拼" }
            if name.contains("注音") || id.lowercased().contains("zhuyin") { return "注" }
            if name.contains("仓颉") || id.lowercased().contains("cangjie") { return "仓" }
            if name.contains("双拼") { return "双" }
            return String(name.prefix(1))
        }
        let letters = name.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if let first = letters.first { return String(first).uppercased() }
        return "A"
    }
}

// MARK: - TIS 封装

enum TISInputSources {
    /// 可选的输入源（只列用户已启用的，未启用的选了也不会生效）
    static func selectables() -> [IMSource] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.compactMap(describe).filter { source in
            !Self.nonKeyboardPrefixes.contains { source.id.hasPrefix($0) }
        }
    }

    /// 系统自带的「非键盘」输入源：表情面板、听写、长按符号、手写
    private static let nonKeyboardPrefixes: [String] = [
        "com.apple.CharacterPaletteIM",
        "com.apple.PressAndHold",
        "com.apple.inputmethod.ironwood",
        "com.apple.inputmethod.handwriting",
        "com.apple.inputmethod.ChineseHandwriting",
    ]

    static func current() -> IMSource? {
        guard let raw = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return describe(raw)
    }

    @discardableResult
    static func select(id: String) -> Bool {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        for source in list {
            if describe(source)?.id == id {
                return TISSelectInputSource(source) == noErr
            }
        }
        return false
    }

    private static func describe(_ source: TISInputSource) -> IMSource? {
        guard let id = stringProperty(source, kTISPropertyInputSourceID),
              boolProperty(source, kTISPropertyInputSourceIsSelectCapable) else { return nil }
        let name = stringProperty(source, kTISPropertyLocalizedName) ?? id
        let languages = arrayProperty(source, kTISPropertyInputSourceLanguages)
        let isChinese = languages.contains { $0.hasPrefix("zh") }
        return IMSource(id: id, name: name, isChinese: isChinese)
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> CFTypeRef? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        property(source, key) as? String
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        (property(source, key) as? Bool) == true
    }

    private static func arrayProperty(_ source: TISInputSource, _ key: CFString) -> [String] {
        (property(source, key) as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

// MARK: - 规则

struct IMAppRule: Codable, Equatable, Identifiable {
    var bundleID: String
    var appName: String
    var sourceID: String
    var sourceName: String
    var id: String { bundleID }
}

struct IMSiteRule: Codable, Equatable, Identifiable {
    /// 域名（如 github.com），后缀匹配
    var domain: String
    var sourceID: String
    var sourceName: String
    var id: String { domain }
}

// MARK: - 服务

@MainActor
final class InputMethodService: ObservableObject {
    /// 光标旁的输入法指示器
    @Published var indicatorEnabled: Bool {
        didSet { ud.set(indicatorEnabled, forKey: Keys.indicator) }
    }
    /// 按 App / 网站自动切换
    @Published var autoSwitchEnabled: Bool {
        didSet {
            ud.set(autoSwitchEnabled, forKey: Keys.autoSwitch)
            reevaluateRules()
        }
    }
    /// 单击 Shift 切换中英文（期间没有按其它键、按住不超过半秒）
    @Published var shiftSwitchEnabled: Bool {
        didSet {
            ud.set(shiftSwitchEnabled, forKey: Keys.shiftSwitch)
            applyShiftMonitor()
        }
    }
    /// 大写锁定键只锁大写（关闭系统的「使用大写锁定键切换 ABC」）
    @Published private(set) var capsLockLocksUppercase: Bool = false
    @Published var appRules: [IMAppRule] {
        didSet { persist(appRules, forKey: Keys.appRules); reevaluateRules() }
    }
    @Published var siteRules: [IMSiteRule] {
        didSet { persist(siteRules, forKey: Keys.siteRules); reevaluateRules() }
    }
    @Published private(set) var currentSource: IMSource?
    @Published private(set) var sources: [IMSource] = []

    var onToast: ((String, String) -> Void)?

    private let ud = UserDefaults.standard
    private enum Keys {
        static let indicator = "input.indicator"
        static let autoSwitch = "input.autoSwitch"
        static let shiftSwitch = "input.shiftSwitch"
        static let appRules = "input.appRules"
        static let siteRules = "input.siteRules"
    }

    /// 系统级：大写锁定键不参与输入法切换
    private static let capsLockSwitchKey = "TISRomanSwitchState"

    private var shiftMonitor: Any?
    private var shiftLocalMonitor: Any?
    private var shiftDownAt: TimeInterval?
    private var shiftPolluted = false
    private var shiftKey: UInt16?
    /// 最近用过的中文 / 非中文输入源，Shift 切换在两者之间来回
    private var lastChineseSourceID: String?
    private var lastNonChineseSourceID: String?
    /// 指示器去重：TIS 切换一次会连发多条通知
    private var lastIndicatorAt: Date = .distantPast
    private var lastIndicatorSourceID: String?

    private var workspaceObserver: NSObjectProtocol?
    private var tisObserver: NSObjectProtocol?
    private var browserTimer: Timer?
    private var watchedBrowser: NSRunningApplication?
    /// 上次自动选中的输入源，避免重复 select
    private var lastAppliedSourceID: String?

    private enum ModuleKeys {
        static let module = "input"
    }
    private var moduleEnabled = true

    init() {
        indicatorEnabled = ud.object(forKey: Keys.indicator) as? Bool ?? true
        autoSwitchEnabled = ud.object(forKey: Keys.autoSwitch) as? Bool ?? false
        shiftSwitchEnabled = ud.object(forKey: Keys.shiftSwitch) as? Bool ?? false
        appRules = Self.load([IMAppRule].self, forKey: Keys.appRules) ?? []
        siteRules = Self.load([IMSiteRule].self, forKey: Keys.siteRules) ?? []
        currentSource = TISInputSources.current()
        sources = TISInputSources.selectables()
        capsLockLocksUppercase = Self.systemCapsLockLocksUppercase()
    }

    deinit {
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        if let tisObserver { DistributedNotificationCenter.default.removeObserver(tisObserver) }
        browserTimer?.invalidate()
    }

    func setModuleEnabled(_ enabled: Bool) {
        moduleEnabled = enabled
        if !enabled {
            stopBrowserWatch()
        }
        applyShiftMonitor()
        reevaluateRules()
    }

    private func reevaluateRules() {
        stopBrowserWatch()
        guard moduleEnabled, autoSwitchEnabled, let app = NSWorkspace.shared.frontmostApplication else { return }
        applyFrontmost(app)
    }

    func start() {
        guard workspaceObserver == nil else { return }
        // 前台 App 变化 → 应用 App 规则 / 启停浏览器监听
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, self.moduleEnabled, self.autoSwitchEnabled else { return }
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self.applyFrontmost(app)
            }
        }
        // 输入源变化 → 刷新当前 + 弹指示器
        tisObserver = DistributedNotificationCenter.default.addObserver(
            forName: .init(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.moduleEnabled else { return }
                self.refreshCurrent(showIndicator: self.indicatorEnabled)
            }
        }
        refreshCurrent(showIndicator: false)
        applyShiftMonitor()
        reevaluateRules()
    }

    func refreshSources() {
        sources = TISInputSources.selectables()
        refreshCurrent(showIndicator: false)
    }

    // MARK: - 自动切换

    /// 用户在界面里手动切一次（顺便验证 TIS 是否可用）
    func selectSource(_ source: IMSource) {
        guard TISInputSources.select(id: source.id) else {
            onToast?(T("输入法切换失败，请确认该输入源仍已启用"), "exclamationmark.triangle")
            refreshSources()
            return
        }
        refreshCurrent(showIndicator: indicatorEnabled)
    }

    private func applyFrontmost(_ app: NSRunningApplication) {
        stopBrowserWatch()
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        if let rule = appRules.first(where: { $0.bundleID == app.bundleIdentifier }) {
            apply(rule: rule.sourceID, reason: rule.appName)
            return
        }
        guard isBrowser(app) else { return }
        watchedBrowser = app
        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.browserTick(app) }
        }
        RunLoop.main.add(timer, forMode: .common)
        browserTimer = timer
        browserTick(app)
    }

    private func browserTick(_ app: NSRunningApplication) {
        guard moduleEnabled, autoSwitchEnabled, app == NSWorkspace.shared.frontmostApplication else {
            stopBrowserWatch()
            return
        }
        guard let url = Self.browserURL(of: app), let host = url.host else { return }
        guard let rule = siteRules.filter({ InputRuleDomain.matches(host: host, domain: $0.domain) })
            .max(by: { $0.domain.count < $1.domain.count }) else { return }
        apply(rule: rule.sourceID, reason: host)
    }

    private func apply(rule sourceID: String, reason: String) {
        guard currentSource?.id != sourceID else { return }
        if TISInputSources.select(id: sourceID) {
            lastAppliedSourceID = sourceID
            Debug.log("input: switched to \(sourceID) for \(reason)")
        }
    }

    private func isBrowser(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }
        return Self.browserBundles.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    static let browserBundles: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "org.mozilla.firefox",
        "com.operasoftware.Opera",
        "com.duckduckgo.macos",
    ]

    private func stopBrowserWatch() {
        browserTimer?.invalidate()
        browserTimer = nil
        watchedBrowser = nil
    }

    // MARK: - 浏览器地址栏

    /// 用辅助功能从浏览器窗口里找出地址栏 URL
    static func browserURL(of app: NSRunningApplication) -> URL? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var rawWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &rawWindow) == .success,
              let window = rawWindow else { return nil }
        // 遍历窗口树，找第一个像地址的文本框
        var found: URL?
        walk(element: window as! AXUIElement, depth: 0, nodeCount: 0) { element in
            guard found == nil else { return false }
            var role: CFTypeRef?
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                  (role as? String) == "AXTextField" else { return true }
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
                  let text = value as? String else { return true }
            if let url = urlLike(text) { found = url; return false }
            return true
        }
        return found
    }

    private static func urlLike(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2048, !trimmed.contains(" ") else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    /// 深度优先遍历 AX 树（限深限量，found 为 false 时提前终止）
    private static func walk(
        element: AXUIElement, depth: Int, nodeCount: Int,
        _ visit: (AXUIElement) -> Bool
    ) {
        guard nodeCount < 400 else { return }
        guard visit(element) else { return }
        guard depth < 10 else { return }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list {
            walk(element: child, depth: depth + 1, nodeCount: nodeCount + 1, visit)
            if nodeCount >= 400 { break }
        }
    }

    // MARK: - 指示器

    private func refreshCurrent(showIndicator: Bool) {
        currentSource = TISInputSources.current()
        Debug.log("input: source changed to \(currentSource?.id ?? "-") show=\(showIndicator)")
        if let currentSource {
            if currentSource.isChinese {
                lastChineseSourceID = currentSource.id
            } else {
                lastNonChineseSourceID = currentSource.id
            }
        }
        if showIndicator, indicatorEnabled, let currentSource {
            let now = Date()
            let repeated = lastIndicatorSourceID == currentSource.id && now.timeIntervalSince(lastIndicatorAt) < 0.4
            if !repeated {
                lastIndicatorSourceID = currentSource.id
                lastIndicatorAt = now
                IndicatorBubble.shared.show(source: currentSource)
            }
        }
    }

    // MARK: - Shift 单击切换

    /// 只在需要时挂监听：Shift 单击（期间没有按其它键、按住不超过 0.5s）→ 中英互换
    private func applyShiftMonitor() {
        let shouldRun = shiftSwitchEnabled && moduleEnabled
        if shouldRun {
            guard shiftMonitor == nil else { return }
            let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            shiftMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handleShiftEvent(event)
            }
            shiftLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handleShiftEvent(event)
                return event
            }
        } else {
            if let shiftMonitor { NSEvent.removeMonitor(shiftMonitor) }
            if let shiftLocalMonitor { NSEvent.removeMonitor(shiftLocalMonitor) }
            shiftMonitor = nil
            shiftLocalMonitor = nil
            shiftDownAt = nil
            shiftPolluted = false
        }
    }

    private func handleShiftEvent(_ event: NSEvent) {
        // 带其它修饰键的一律不算（⌘⇧4、⌃⇧ 这类）
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.type {
        case .flagsChanged:
            let isShiftKey = event.keyCode == 56 || event.keyCode == 60
            guard isShiftKey else {
                // 其它修饰键按下会污染这次 Shift
                if shiftDownAt != nil { shiftPolluted = true }
                return
            }
            let otherModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
            if !flags.intersection(otherModifiers).isEmpty {
                if flags.contains(.shift) {
                    if shiftDownAt != nil { shiftPolluted = true }
                } else {
                    shiftDownAt = nil
                    shiftKey = nil
                    shiftPolluted = false
                }
                return
            }
            let pressed = flags.contains(.shift)
            if pressed {
                if shiftDownAt == nil {
                    shiftDownAt = event.timestamp
                    shiftKey = event.keyCode
                    shiftPolluted = false
                } else if shiftKey != event.keyCode {
                    shiftPolluted = true
                }
            } else if let down = shiftDownAt {
                let duration = event.timestamp - down
                let polluted = shiftPolluted
                shiftDownAt = nil
                shiftKey = nil
                shiftPolluted = false
                guard !polluted, duration <= 0.5 else { return }
                toggleBetweenChineseAndLatin()
            }
        default:
            // 按下任何键 / 点鼠标 / 滚轮 → 这次 Shift 是在配合输入，不是切换手势
            if shiftDownAt != nil { shiftPolluted = true }
        }
    }

    /// Shift 手势：中文 ⇄ 英文 来回切（英文优先 ABC，和 Windows 输入法一致）
    private func toggleBetweenChineseAndLatin() {
        guard let current = currentSource else { return }
        let abc = "com.apple.keylayout.ABC"
        let targetID: String?
        if current.isChinese {
            if sources.contains(where: { $0.id == abc }) {
                targetID = abc
            } else {
                targetID = lastNonChineseSourceID ?? sources.first(where: { !$0.isChinese })?.id
            }
        } else {
            targetID = lastChineseSourceID ?? sources.first(where: { $0.isChinese })?.id
        }
        guard let targetID, targetID != current.id else { return }
        Debug.log("input: shift toggle \(current.id) -> \(targetID)")
        if TISInputSources.select(id: targetID) {
            refreshCurrent(showIndicator: indicatorEnabled)
        }
    }

    // MARK: - 大写锁定键

    /// 系统偏好里的「使用大写锁定键切换 ABC」是否为关（关 = 只锁大写）
    private static func systemCapsLockLocksUppercase() -> Bool {
        (CFPreferencesCopyValue(capsLockSwitchKey as CFString, kCFPreferencesAnyApplication,
                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.intValue == 0
    }

    /// 写系统偏好：关掉「大写锁定键切换 ABC」，让 Caps Lock 只做大写锁定
    func setCapsLockLocksUppercase(_ enabled: Bool) {
        let key = Self.capsLockSwitchKey as CFString
        let previous = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue(key, NSNumber(value: enabled ? 0 : 1), kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let synced = CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard synced, Self.systemCapsLockLocksUppercase() == enabled else {
            CFPreferencesSetValue(key, previous, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            onToast?(T("键盘设置未保存，请在系统设置中重试"), "exclamationmark.triangle")
            return
        }
        capsLockLocksUppercase = Self.systemCapsLockLocksUppercase()
        onToast?(T("已保存键盘设置，可能需要重新登录后生效"), "capslock")
    }

    // MARK: - 规则管理

    @discardableResult
    func addAppRule(at url: URL) -> Bool {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            onToast?(T("无法识别这个应用"), "exclamationmark.triangle")
            return false
        }
        guard appRules.first(where: { $0.bundleID == bundleID }) == nil else {
            onToast?(T("这个应用已有规则"), "exclamationmark.triangle")
            return false
        }
        let appName = FileManager.default.displayName(atPath: url.path)
        // 默认给英文源（规则最常见的用途），菜单里可以再改成任意输入法
        let source = sources.first(where: { !$0.isChinese }) ?? sources.first
        guard let source else {
            onToast?(T("没有可用的输入法"), "exclamationmark.triangle")
            return false
        }
        appRules.append(IMAppRule(
            bundleID: bundleID, appName: appName,
            sourceID: source.id, sourceName: source.name
        ))
        onToast?(TF("已添加 %@，以后切过去自动用「%@」", appName, source.name), "arrow.triangle.swap")
        return true
    }

    func removeAppRule(bundleID: String) {
        appRules.removeAll { $0.bundleID == bundleID }
    }

    func updateAppRule(bundleID: String, source: IMSource) {
        guard let index = appRules.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        appRules[index].sourceID = source.id
        appRules[index].sourceName = source.name
    }

    @discardableResult
    func addSiteRule(domain: String, source: IMSource) -> Bool {
        guard let domain = InputRuleDomain.normalize(domain),
              siteRules.first(where: { InputRuleDomain.normalize($0.domain) == domain }) == nil else { return false }
        siteRules.append(IMSiteRule(domain: domain, sourceID: source.id, sourceName: source.name))
        return true
    }

    func removeSiteRule(domain: String) {
        siteRules.removeAll { $0.domain == domain }
    }

    func updateSiteRule(domain: String, source: IMSource) {
        guard let index = siteRules.firstIndex(where: { $0.domain == domain }) else { return }
        siteRules[index].sourceID = source.id
        siteRules[index].sourceName = source.name
    }

    // MARK: - 持久化

    private nonisolated static func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            ud.set(data, forKey: key)
        }
    }
}

// MARK: - 指示器浮窗

/// 贴着光标弹出的输入法胶囊，短暂显示后淡出
@MainActor
final class IndicatorBubble {
    static let shared = IndicatorBubble()
    private var panel: NSPanel?
    private var hosting: TransparentHostingView<IndicatorBubbleView>?
    private var hideWork: DispatchWorkItem?
    /// 同一标签短时间内重复调用（TIS 会连发通知）只处理一次
    private var lastLabel: String?
    private var lastShownAt: Date = .distantPast

    func show(source: IMSource) {
        let now = Date()
        if lastLabel == source.shortLabel, now.timeIntervalSince(lastShownAt) < 0.35 { return }
        lastLabel = source.shortLabel
        lastShownAt = now
        let size = CGSize(width: 46, height: 34)
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .init(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let hosting = TransparentHostingView(rootView: IndicatorBubbleView(label: source.shortLabel))
            hosting.frame = NSRect(origin: .zero, size: size)
            RoundedWindowSurface.configure(hosting, radius: 12)
            panel.contentView = hosting
            self.panel = panel
            self.hosting = hosting
        }
        guard let panel, let hosting else { return }
        hosting.rootView = IndicatorBubbleView(label: source.shortLabel)

        // 位置：光标插入点优先，其次聚焦控件 / 前台窗口，最后鼠标
        let anchor = CaretLocator.probe()
        let origin: NSPoint
        if let caret = anchor.caret ?? anchor.field ?? anchor.window {
            origin = NSPoint(x: caret.maxX + 10, y: caret.maxY - size.height)
        } else {
            let mouse = NSEvent.mouseLocation
            origin = NSPoint(x: mouse.x + 14, y: mouse.y - size.height - 6)
        }
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4),
                y: min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
            ))
        } else {
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
        panel.alphaValue = 1
        Debug.log("input: indicator shown frame=\(panel.frame) label=\(source.shortLabel)")

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}

struct IndicatorBubbleView: View {
    let label: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}
