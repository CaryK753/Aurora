import AppKit
import SwiftUI
import XCTest
@testable import Aurora

@MainActor final class SettingsPageTests: XCTestCase {
    func testCompactSettingsNavigationAndModuleSearch() async throws {
        guard ProcessInfo.processInfo.environment["AURORA_TEST_CAPTURE_WINDOW"] == "1" else {
            throw XCTSkip("Requires a local window server")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let state = AppState(preview: true)
        let initialAppearance = app.appearance
        let initialLanguage = state.settings.language
        let defaults = UserDefaults.standard
        let oldLanguage = defaults.object(forKey: "settings.language")
        let oldModules = defaults.object(forKey: "settings.disabledModules")
        let quitPreference = defaults.object(forKey: "settings.confirmBeforeQuit")
        let enabled = state.settings.isEnabled(.recorder)
        defer {
            state.settings.language = initialLanguage
            state.settings.setModule(.recorder, enabled: enabled)
            defaults.set(oldLanguage, forKey: "settings.language")
            defaults.set(quitPreference, forKey: "settings.confirmBeforeQuit")
            defaults.set(oldModules, forKey: "settings.disabledModules")
            app.appearance = initialAppearance
        }
        state.module = .settings
        state.settings.language = .zhHans
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: PanelController.panelSize),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AuroraRootView(state: state))
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(350))
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, key as CFString, &value)
            return value
        }
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &windows)
        let root = try XCTUnwrap((windows as? [AXUIElement])?.first)
        func find(_ text: String, role: String? = nil, below e: AXUIElement? = nil, depth: Int = 0) -> AXUIElement? {
            let element = e ?? root
            guard depth < 25 else { return nil }
            let labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, kAXPlaceholderValueAttribute].compactMap {
                attribute(element, $0) as? String
            }
            let titleElement = attribute(element, kAXTitleUIElementAttribute)
            let associatedTitle = titleElement.flatMap { attribute($0 as! AXUIElement, kAXValueAttribute) as? String }
            if (labels.contains(text) || associatedTitle == text), role == nil || attribute(element, kAXRoleAttribute) as? String == role { return element }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let found = find(text, role: role, below: child, depth: depth + 1) { return found }
            }
            return nil
        }
        func press(_ title: String, role: String? = nil) async throws {
            let item = try XCTUnwrap(find(title, role: role), title)
            XCTAssertEqual(AXUIElementPerformAction(item, kAXPressAction as CFString), .success)
            try await Task.sleep(for: .milliseconds(120))
        }
        XCTAssertNotNil(find("启动与退出"))
        try await press("深色", role: kAXButtonRole)
        XCTAssertEqual(state.settings.appearance, .dark)
        let confirmed = AuroraAlert.confirmBeforeQuit
        try await press("退出前确认", role: kAXCheckBoxRole)
        XCTAssertEqual(AuroraAlert.confirmBeforeQuit, !confirmed)
        try await press("模块", role: kAXRadioButtonRole)
        let search = try XCTUnwrap(find("搜索模块", role: kAXTextFieldRole))
        func searchFor(_ text: String) async throws {
            XCTAssertEqual(AXUIElementSetAttributeValue(search, kAXFocusedAttribute as CFString, kCFBooleanTrue), .success)
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
            try await Task.sleep(for: .milliseconds(120))
        }
        try await searchFor("__missing__")
        XCTAssertNotNil(find("没有匹配的模块"))
        try await searchFor("录屏")
        try await press("录屏", role: kAXCheckBoxRole)
        XCTAssertEqual(state.settings.isEnabled(.recorder), !enabled)
        XCTAssertEqual(state.settings.visibleModules.contains(.recorder), !enabled)
        try await press("清除搜索")
        XCTAssertNotNil(find("截图", role: kAXCheckBoxRole))
        try await press("权限", role: kAXRadioButtonRole)
        XCTAssertNotNil(find("重新检测", role: kAXButtonRole))
        try await press("关于", role: kAXRadioButtonRole)
        XCTAssertNotNil(find("查看这一版的新功能", role: kAXButtonRole))
        func scrollViews(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { ($0 as? NSScrollView).map { [$0] } ?? scrollViews(in: $0) }
        }
        let scroll = try XCTUnwrap(scrollViews(in: try XCTUnwrap(window.contentView)).first {
            ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height
        })
        let document = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        XCTAssertNotNil(find("重置所有设置", role: kAXButtonRole))
        try await press("通用", role: kAXRadioButtonRole)
        state.settings.language = .en
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(find("Startup & Quit"))
        try await press("Modules", role: kAXRadioButtonRole)
        XCTAssertNotNil(find("Search modules", role: kAXTextFieldRole))
        window.setContentSize(CGSize(width: 900, height: 680))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNotNil(find("Search modules", role: kAXTextFieldRole))
    }
}
