//  SettingsService.swift
//  Aurora — 设置：语言、开机自启、模块开关、权限、版本

import AppKit
import ApplicationServices
import Combine
import ServiceManagement

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return T("跟随系统")
        case .light: return T("浅色")
        case .dark: return T("深色")
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class SettingsService: ObservableObject {
    /// 预览/截图模式：只改内存里的外观，不写偏好，避免把调试参数留成用户设置
    private let persistPreferences: Bool

    @Published var appearance: AppAppearance {
        didSet {
            guard appearance != oldValue else { return }
            if persistPreferences {
                UserDefaults.standard.set(appearance.rawValue, forKey: "settings.appearance")
            }
            applyAppearance()
        }
    }

    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: "settings.language")
            L10n.effective = L10n.resolve(language)
            NotificationCenter.default.post(name: .auroraLanguageChanged, object: nil)
        }
    }

    @Published private(set) var disabledModules: Set<String>
    /// 侧边栏顺序（只存可开关的模块；概览固定第一，设置固定最后）
    @Published private(set) var moduleOrder: [String]
    @Published private(set) var launchAtLogin: Bool = false
    @Published private(set) var launchAtLoginError: String?

    let version: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    let build: String = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }

    init(persistPreferences: Bool = true) {
        self.persistPreferences = persistPreferences
        if persistPreferences {
            let storedAppearance = UserDefaults.standard.string(forKey: "settings.appearance") ?? AppAppearance.system.rawValue
            appearance = AppAppearance(rawValue: storedAppearance) ?? .system
        } else {
            appearance = .system
        }

        let stored = UserDefaults.standard.string(forKey: "settings.language") ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: stored) ?? .system
        disabledModules = Set(UserDefaults.standard.stringArray(forKey: "settings.disabledModules") ?? [])
        moduleOrder = UserDefaults.standard.stringArray(forKey: "settings.moduleOrder") ?? []
        L10n.effective = L10n.resolve(language)
        refreshLaunchAtLogin()
        applyAppearance()
    }

    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    // MARK: - 模块

    func isEnabled(_ module: AuroraModule) -> Bool {
        !disabledModules.contains(module.rawValue)
    }

    func setModule(_ module: AuroraModule, enabled: Bool, userInitiated: Bool = true) {
        guard module.isToggleable else { return }
        if module == .trackpad, userInitiated {
            UserDefaults.standard.set(true, forKey: "settings.trackpadUserChoice")
        }
        if enabled {
            disabledModules.remove(module.rawValue)
        } else {
            disabledModules.insert(module.rawValue)
        }
        UserDefaults.standard.set(Array(disabledModules), forKey: "settings.disabledModules")
    }

    var visibleModules: [AuroraModule] {
        let enabled = AuroraModule.allCases.filter { isEnabled($0) }
        var middle = enabled.filter(\.isToggleable)
        let order = moduleOrder
        middle.sort { lhs, rhs in
            let left = order.firstIndex(of: lhs.rawValue) ?? Int.max
            let right = order.firstIndex(of: rhs.rawValue) ?? Int.max
            if left != right { return left < right }
            let li = AuroraModule.allCases.firstIndex(of: lhs) ?? 0
            let ri = AuroraModule.allCases.firstIndex(of: rhs) ?? 0
            return li < ri
        }
        var result: [AuroraModule] = []
        if enabled.contains(.overview) { result.append(.overview) }
        result.append(contentsOf: middle)
        if enabled.contains(.settings) { result.append(.settings) }
        return result
    }

    /// 拖动排序：index 是「可开关模块」里的目标位置
    func moveModule(_ module: AuroraModule, to index: Int) {
        guard module.isToggleable else { return }
        var middle = visibleModules.filter(\.isToggleable)
        guard let from = middle.firstIndex(of: module) else { return }
        let target = min(max(index, 0), middle.count - 1)
        guard from != target else { return }
        let item = middle.remove(at: from)
        middle.insert(item, at: target)
        moduleOrder = middle.map(\.rawValue)
        UserDefaults.standard.set(moduleOrder, forKey: "settings.moduleOrder")
    }

    // MARK: - 开机自启

    func refreshLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            Debug.log("launchAtLogin failed: \(error.localizedDescription)")
        }
        refreshLaunchAtLogin()
    }

    // MARK: - 重置

    func resetAll() {
        setLaunchAtLogin(false)
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        disabledModules = []
        moduleOrder = []
        language = .system
        appearance = .system
        refreshLaunchAtLogin()
    }
}

extension Notification.Name {
    static let auroraLanguageChanged = Notification.Name("aurora.languageChanged")
    static let auroraAccessibilityChanged = Notification.Name("aurora.accessibilityChanged")
}
