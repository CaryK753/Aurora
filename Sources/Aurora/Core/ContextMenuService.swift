//  ContextMenuService.swift
//  Aurora — 右键菜单管理：读取/写入 pbs.plist 的 FinderActive 与 NSServicesStatus，
//  并扫描系统与第三方 .appex / .workflow 以列出可管理的菜单项。

import AppKit
import Combine

struct ContextMenuItem: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case quickAction     // Finder 右键「快速操作」
        case service         // 右键「服务」子菜单
        case finderExtension // 第三方 Finder 扩展

        var title: String {
            switch self {
            case .quickAction: return T("快速操作")
            case .service: return T("服务")
            case .finderExtension: return T("Finder 扩展")
            }
        }

        var symbol: String {
            switch self {
            case .quickAction: return "bolt.fill"
            case .service: return "square.stack.3d.up.fill"
            case .finderExtension: return "puzzlepiece.extension.fill"
            }
        }
    }

    let id: String
    var title: String
    var provider: String
    var kind: Kind
    var isEnabled: Bool
    var writable: Bool
}

@MainActor
final class ContextMenuService: ObservableObject {
    @Published private(set) var items: [ContextMenuItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastApplied = Date.distantPast

    private var finderActive: [String: Bool] = [:]
    private var serviceStatus: [String: [String: Any]] = [:]
    private var foundBundles: [String: (name: String, kind: ContextMenuItem.Kind)] = [:]
    private var pendingFinderRestart: Timer?

    private let prefsDomain = "pbs" as CFString

    init() {
        reload()
    }

    // MARK: - 读取

    func reload() {
        finderActive = (CFPreferencesCopyAppValue("FinderActive" as CFString, prefsDomain) as? [String: Bool]) ?? [:]
        serviceStatus = (CFPreferencesCopyAppValue("NSServicesStatus" as CFString, prefsDomain) as? [String: [String: Any]]) ?? [:]
        rebuildList()

        if foundBundles.isEmpty {
            scanBundles()
        }
    }

    private func rebuildList() {
        var result: [ContextMenuItem] = []

        // 1) pbs 中已登记的右键项（快速操作 / 快捷指令动作）
        for (key, enabled) in finderActive.sorted(by: { $0.key < $1.key }) {
            let bundleID = key.hasPrefix("APPEXTENSION-") ? String(key.dropFirst("APPEXTENSION-".count)) : key
            let discovered = foundBundles[bundleID]
            let title = discovered?.name ?? humanize(key)
            let provider = discovered?.name == nil ? providerFor(key) : (discovered?.name ?? "")
            result.append(
                ContextMenuItem(
                    id: key,
                    title: title,
                    provider: provider.isEmpty ? ContextMenuItem.Kind.quickAction.title : provider,
                    kind: .quickAction,
                    isEnabled: enabled,
                    writable: true
                )
            )
        }

        // 2) 扫描到但未在 pbs 登记的快速操作 / 扩展 / 服务
        for (bundleID, info) in foundBundles.sorted(by: { $0.value.name < $1.value.name }) {
            switch info.kind {
            case .quickAction:
                let key = "APPEXTENSION-\(bundleID)"
                if finderActive[key] == nil {
                    result.append(
                        ContextMenuItem(id: key, title: info.name, provider: T("快速操作"), kind: .quickAction, isEnabled: true, writable: true)
                    )
                }
            case .finderExtension:
                if !result.contains(where: { $0.id == bundleID }) {
                    result.append(
                        ContextMenuItem(id: bundleID, title: info.name, provider: T("Finder 扩展"), kind: .finderExtension, isEnabled: true, writable: true)
                    )
                }
            case .service:
                if !result.contains(where: { $0.id == bundleID }) {
                    result.append(
                        ContextMenuItem(id: bundleID, title: info.name, provider: T("服务"), kind: .service, isEnabled: true, writable: true)
                    )
                }
            }
        }

        // 3) NSServicesStatus 中的服务项
        for (key, value) in serviceStatus.sorted(by: { $0.key < $1.key }) {
            let enabled = (value["enabled_context_menu"] as? Bool) ?? (value["enabled_context_menu"] as? Int == 1)
            let parts = key.components(separatedBy: " - ")
            let title = parts.first ?? key
            result.append(
                ContextMenuItem(
                    id: key,
                    title: title,
                    provider: parts.count > 1 ? parts[1] : T("服务"),
                    kind: .service,
                    isEnabled: enabled,
                    writable: true
                )
            )
        }

        items = result.sorted {
            if $0.kind == $1.kind { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    /// 把 bundle id / 动作标识转成可读名称（尽可能贴近系统中文显示）
    private func humanize(_ key: String) -> String {
        var text = key
        if text.hasPrefix("APPEXTENSION-") { text = String(text.dropFirst("APPEXTENSION-".count)) }

        let known: [(needle: String, name: String)] = [
            ("CreatePDFQuickAction", T("创建 PDF")),
            ("MarkupQuickAction", T("标记")),
            ("TrimQuickAction", T("裁剪")),
            ("RotateQuickAction", T("旋转")),
            ("remove-background", T("移除背景")),
            ("image.convert.finder", T("转换图像格式")),
            ("image.removebackground", T("移除图像背景")),
            ("CreatePDF", T("创建 PDF")),
            ("QuickAction", "")
        ]
        for entry in known where text.localizedCaseInsensitiveContains(entry.needle) {
            if !entry.name.isEmpty { return entry.name }
        }

        for prefix in ["com.apple.finder.", "com.apple.pixelmator.", "is.workflow.actions.", "com.apple."] {
            if text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        }
        if text.hasSuffix(".finder") { text = String(text.dropLast(".finder".count)) }

        text = text
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        text = text.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        text = text.replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1 $2", options: .regularExpression)

        let words = text.split(separator: " ").map { word -> String in
            let value = String(word)
            if value.count <= 3, value == value.uppercased() { return value }
            return value.prefix(1).uppercased() + value.dropFirst()
        }
        let result = words.joined(separator: " ")
        return result.isEmpty ? key : result
    }

    private func providerFor(_ key: String) -> String {
        if key.hasPrefix("is.workflow.actions.") { return T("快捷指令") }
        return ContextMenuItem.Kind.quickAction.title
    }

    // MARK: - 扫描

    private func scanBundles() {
        isScanning = true
        let roots = [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications"
        ]
        let serviceDirs = [
            NSHomeDirectory() + "/Library/Services",
            "/Library/Services",
            "/System/Library/Services"
        ]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [String: (name: String, kind: ContextMenuItem.Kind)] = [:]

            func inspect(_ url: URL) {
                guard let bundle = Bundle(url: url), let info = bundle.infoDictionary else { return }
                guard let identifier = info["CFBundleIdentifier"] as? String else { return }
                let name = (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                if let extensionInfo = info["NSExtension"] as? [String: Any],
                   let point = extensionInfo["NSExtensionPointIdentifier"] as? String {
                    if point == "com.apple.services" {
                        found[identifier] = (name, .quickAction)
                    } else if point == "com.apple.FinderSync" {
                        found[identifier] = (name, .finderExtension)
                    }
                }
                if info["NSServices"] != nil, found[identifier] == nil {
                    found[identifier] = (name, .service)
                }
            }

            for root in roots {
                let fileManager = FileManager.default
                guard let enumerator = fileManager.enumerator(
                    at: URL(fileURLWithPath: root),
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                var visited = 0
                for case let url as URL in enumerator {
                    visited += 1
                    if visited > 12_000 { break }
                    let path = url.path
                    if path.contains(".app/Contents/PlugIns") || path.hasSuffix(".appex") {
                        if path.hasSuffix(".appex") { inspect(url) }
                    }
                    // 深度限制：/Applications 下最多 5 层
                    if url.pathComponents.count > 7 {
                        enumerator.skipDescendants()
                    }
                }
            }

            for dir in serviceDirs {
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: dir),
                    includingPropertiesForKeys: nil
                ) else { continue }
                for entry in entries where entry.pathExtension == "workflow" || entry.pathExtension == "service" {
                    inspect(entry)
                }
            }

            let snapshot = found
            Task { @MainActor in
                guard let self else { return }
                self.foundBundles = snapshot
                self.isScanning = false
                self.rebuildList()
            }
        }
    }

    // MARK: - 写入

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        items[index].isEnabled = enabled

        switch item.kind {
        case .quickAction:
            finderActive[id] = enabled
            CFPreferencesSetAppValue("FinderActive" as CFString, finderActive as CFDictionary, prefsDomain)
            CFPreferencesAppSynchronize(prefsDomain)

        case .service:
            var entry = serviceStatus[id] ?? [:]
            entry["enabled_context_menu"] = enabled ? 1 : 0
            entry["enabled_services_menu"] = enabled ? 1 : 0
            serviceStatus[id] = entry
            CFPreferencesSetAppValue("NSServicesStatus" as CFString, serviceStatus as CFDictionary, prefsDomain)
            CFPreferencesAppSynchronize(prefsDomain)

        case .finderExtension:
            let argument = enabled ? "use" : "ignore"
            runPluginkit(argument: argument, identifier: id)
        }

        lastApplied = Date()
        scheduleFinderRefresh()
    }

    private func runPluginkit(argument: String, identifier: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-e", argument, "-i", identifier]
        try? process.run()
        process.waitUntilExit()
    }

    private func scheduleFinderRefresh() {
        pendingFinderRestart?.invalidate()
        pendingFinderRestart = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { _ in
            Self.restartFinder()
        }
    }

    static func restartFinder() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try? process.run()
    }

    func refreshFinderNow() {
        Self.restartFinder()
    }

    /// 供配置导入使用：启用 RClick 的 Finder 扩展
    func enableRClickExtension() {
        if let item = items.first(where: {
            $0.id.localizedCaseInsensitiveContains("rclick") || $0.title.localizedCaseInsensitiveContains("rclick")
        }) {
            if !item.isEnabled { setEnabled(true, for: item.id) }
            return
        }
        runPluginkit(argument: "use", identifier: "cn.wflixu.RClick.FinderSyncExt")
        lastApplied = Date()
        scheduleFinderRefresh()
    }
}
