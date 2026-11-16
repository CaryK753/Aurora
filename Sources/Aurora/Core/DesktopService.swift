//  DesktopService.swift
//  Aurora — 桌面图标显示 / 隐藏（com.apple.finder CreateDesktop）

import AppKit
import Combine

@MainActor
final class DesktopService: ObservableObject {
    @Published private(set) var iconsVisible: Bool
    @Published private(set) var showHiddenFiles: Bool
    @Published private(set) var showAllExtensions: Bool
    @Published private(set) var lastToggle = Date.distantPast
    @Published private(set) var lastError: String?

    private let domain = "com.apple.finder" as CFString

    init() {
        iconsVisible = Self.readVisible()
        showHiddenFiles = (CFPreferencesCopyAppValue("AppleShowAllFiles" as CFString, "com.apple.finder" as CFString) as? Bool) ?? false
        showAllExtensions = (CFPreferencesCopyAppValue("AppleShowAllExtensions" as CFString, kCFPreferencesAnyApplication) as? Bool) ?? false
    }

    @discardableResult
    func setShowHiddenFiles(_ enabled: Bool) -> Bool {
        guard save("AppleShowAllFiles", enabled, app: domain) else { return false }
        showHiddenFiles = enabled
        return refreshFinder()
    }

    @discardableResult
    func setShowAllExtensions(_ enabled: Bool) -> Bool {
        guard save("AppleShowAllExtensions", enabled, app: kCFPreferencesAnyApplication) else { return false }
        showAllExtensions = enabled
        return refreshFinder()
    }

    private func save(_ key: String, _ value: Bool, app: CFString) -> Bool {
        lastError = nil
        let old = CFPreferencesCopyValue(key as CFString, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetValue(key as CFString, NSNumber(value: value), app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let synced = CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let stored = CFPreferencesCopyValue(key as CFString, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber
        guard synced, stored?.boolValue == value else {
            CFPreferencesSetValue(key as CFString, old, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            lastError = T("桌面设置未保存，请在系统设置中重试")
            return false
        }
        return true
    }

    private func refreshFinder() -> Bool {
        guard Self.restartFinder() else {
            lastError = T("设置已保存，但未能刷新访达，请手动重新打开访达")
            return false
        }
        return true
    }

    static func readVisible() -> Bool {
        if let value = CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString) as? Bool {
            return value
        }
        return true
    }

    @discardableResult
    func setIconsVisible(_ visible: Bool) -> Bool {
        guard save("CreateDesktop", visible, app: domain) else { return false }
        iconsVisible = visible
        lastToggle = Date()
        return refreshFinder()
    }

    func toggle() {
        setIconsVisible(!iconsVisible)
    }

    @discardableResult
    static func restartFinder() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// 打开访达设置面板，方便用户核对相关项
    func openFinderSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        }
    }
}
