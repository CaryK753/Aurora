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

    private let domain = "com.apple.finder" as CFString

    init() {
        iconsVisible = Self.readVisible()
        showHiddenFiles = (CFPreferencesCopyAppValue("AppleShowAllFiles" as CFString, "com.apple.finder" as CFString) as? Bool) ?? false
        showAllExtensions = (CFPreferencesCopyAppValue("AppleShowAllExtensions" as CFString, kCFPreferencesAnyApplication) as? Bool) ?? false
    }

    func setShowHiddenFiles(_ enabled: Bool) {
        showHiddenFiles = enabled
        CFPreferencesSetAppValue("AppleShowAllFiles" as CFString, NSNumber(value: enabled), domain)
        CFPreferencesAppSynchronize(domain)
        Self.restartFinder()
    }

    func setShowAllExtensions(_ enabled: Bool) {
        showAllExtensions = enabled
        CFPreferencesSetValue("AppleShowAllExtensions" as CFString, NSNumber(value: enabled),
                              kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        Self.restartFinder()
    }

    static func readVisible() -> Bool {
        if let value = CFPreferencesCopyAppValue("CreateDesktop" as CFString, "com.apple.finder" as CFString) as? Bool {
            return value
        }
        return true
    }

    func setIconsVisible(_ visible: Bool) {
        iconsVisible = visible
        CFPreferencesSetAppValue("CreateDesktop" as CFString, NSNumber(value: visible), domain)
        CFPreferencesAppSynchronize(domain)
        lastToggle = Date()
        Self.restartFinder()
    }

    func toggle() {
        setIconsVisible(!iconsVisible)
    }

    static func restartFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try? process.run()
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
