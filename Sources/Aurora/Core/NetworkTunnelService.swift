//  NetworkTunnelService.swift
//  Aurora — 把透明代理注册进「系统设置 › VPN」
//
//  列表里的名字固定是 Aurora。扩展要真正加载，描述文件里得有
//  app-proxy-provider-systemextension。没有这项授权时不要把它写进主程序的 entitlements，
//  否则系统会直接杀掉 Aurora。

import AppKit
import Foundation
import NetworkExtension
import SystemExtensions

@MainActor
final class NetworkTunnelService: ObservableObject {
    static let extensionBundleID = "com.cary.aurora.tunnel"
    static let vpnName = "Aurora"

    enum Mode: String, CaseIterable, Identifiable {
        case rule, direct, global

        var id: String { rawValue }

        var title: String {
            switch self {
            case .rule: return T("规则")
            case .direct: return T("直连")
            case .global: return T("全局")
            }
        }
    }

    enum ProxyKind: String, CaseIterable, Identifiable {
        case socks5, http

        var id: String { rawValue }

        var title: String {
            switch self {
            case .socks5: return "SOCKS5"
            case .http: return "HTTP"
            }
        }
    }

    enum InstallState: Equatable {
        case unknown
        case missingBundle
        case needsApproval
        case installed
        case failed
    }

    @Published var mode: Mode
    @Published var proxyKind: ProxyKind
    @Published var proxyHost: String
    @Published var proxyPort: String
    @Published var rulesText: String
    @Published private(set) var vpnStatus: NEVPNStatus = .invalid
    @Published private(set) var installState: InstallState = .unknown
    @Published private(set) var statusText: String = ""
    @Published private(set) var lastError: String?
    @Published private(set) var isBusy = false

    private let defaults = UserDefaults.standard
    private var manager: NETransparentProxyManager?
    private var installer: SystemExtensionInstaller?
    private var statusObserver: NSObjectProtocol?
    private var wantsTunnel = false

    init() {
        mode = Mode(rawValue: defaults.string(forKey: "network.mode") ?? "") ?? .rule
        proxyKind = ProxyKind(rawValue: defaults.string(forKey: "network.proxyKind") ?? "") ?? .socks5
        proxyHost = defaults.string(forKey: "network.proxyHost") ?? ""
        proxyPort = defaults.string(forKey: "network.proxyPort") ?? ""
        rulesText = defaults.string(forKey: "network.rules") ?? ProxyRuleEngine.defaultText
        statusText = T("Aurora 还没有出现在系统设置里")
        refresh()
    }

    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
    }

    var isConnected: Bool { vpnStatus == .connected || vpnStatus == .connecting || vpnStatus == .reasserting }

    var ruleIssues: [ProxyRuleEngine.Issue] { ProxyRuleEngine.parse(rulesText).issues }

    func updateMode(_ mode: Mode) {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: "network.mode")
    }

    func updateKind(_ kind: ProxyKind) {
        proxyKind = kind
        defaults.set(kind.rawValue, forKey: "network.proxyKind")
    }

    func updateHost(_ host: String) {
        proxyHost = host
        defaults.set(host, forKey: "network.proxyHost")
    }

    func updatePort(_ port: String) {
        let filtered = port.filter(\.isNumber)
        proxyPort = String(filtered.prefix(5))
        defaults.set(proxyPort, forKey: "network.proxyPort")
    }

    func updateRules(_ text: String) {
        rulesText = text
        defaults.set(text, forKey: "network.rules")
    }

    func openVPNSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Network-Settings.extension?VPN",
            "x-apple.systempreferences:com.apple.preference.network?VPN"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    func openExtensionSettings() {
        let raw = "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.system_extension.network_extension.extension-point"
        if let url = URL(string: raw) { NSWorkspace.shared.open(url) }
    }

    /// 安装扩展，并把 Aurora 写进系统设置的 VPN 列表。已连接时会先断开再按新配置连上。
    func installAndApply(connect: Bool) {
        guard !isBusy else { return }
        lastError = nil
        let issues = ruleIssues
        if mode == .rule, !issues.isEmpty {
            lastError = TF("第 %d 行无法识别：%@", issues[0].line, issues[0].text)
            return
        }
        if mode != .direct, !proxyReady {
            lastError = T("先填代理主机和端口")
            return
        }
        guard FileManager.default.fileExists(atPath: Self.extensionURL.path) else {
            installState = .missingBundle
            lastError = T("扩展不在应用包里，请用完整的 Aurora.app")
            statusText = lastError ?? ""
            return
        }
        wantsTunnel = connect
        isBusy = true
        statusText = T("正在写入系统设置")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionBundleID,
            queue: .main
        )
        let installer = SystemExtensionInstaller(
            onApproval: { [weak self] in
                guard let self else { return }
                self.installState = .needsApproval
                self.isBusy = false
                self.statusText = T("等待系统批准网络扩展")
                self.lastError = T("到系统设置里允许 Aurora 的网络扩展，然后再写一次")
            },
            onFinish: { [weak self] in
                guard let self else { return }
                self.installState = .installed
                self.saveAndMaybeConnect()
            },
            onError: { [weak self] message in
                guard let self else { return }
                self.installState = .failed
                self.isBusy = false
                self.wantsTunnel = false
                self.lastError = message
                self.statusText = T("网络扩展没有加载")
            }
        )
        self.installer = installer
        request.delegate = installer
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func disconnect() {
        wantsTunnel = false
        manager?.connection.stopVPNTunnel()
    }

    func refresh() {
        NETransparentProxyManager.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                }
                let found = managers?.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.extensionBundleID
                }
                self.manager = found
                self.observe(found?.connection)
                if found == nil {
                    self.vpnStatus = .invalid
                    if self.installState != .needsApproval {
                        self.statusText = T("Aurora 还没有出现在系统设置里")
                    }
                }
            }
        }
    }

    private var proxyReady: Bool {
        let host = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let port = Int(proxyPort), (1...65535).contains(port) else { return false }
        return true
    }

    private var configuration: [String: Any] {
        [
            ProxyConfigKey.mode: mode.rawValue,
            ProxyConfigKey.proxyKind: proxyKind.rawValue,
            ProxyConfigKey.proxyHost: proxyHost.trimmingCharacters(in: .whitespacesAndNewlines),
            ProxyConfigKey.proxyPort: Int(proxyPort) ?? 0,
            ProxyConfigKey.rules: rulesText
        ]
    }

    private func saveAndMaybeConnect() {
        NETransparentProxyManager.loadAllFromPreferences { [weak self] managers, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.fail(error.localizedDescription)
                    return
                }
                let manager = managers?.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.extensionBundleID
                } ?? NETransparentProxyManager()
                let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
                proto.providerBundleIdentifier = Self.extensionBundleID
                proto.serverAddress = self.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Aurora" : self.proxyHost
                proto.providerConfiguration = self.configuration
                proto.disconnectOnSleep = false
                manager.protocolConfiguration = proto
                manager.localizedDescription = Self.vpnName
                manager.isEnabled = true
                manager.saveToPreferences { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error {
                            self.fail(error.localizedDescription)
                            return
                        }
                        manager.loadFromPreferences { [weak self] error in
                            Task { @MainActor in
                                guard let self else { return }
                                if let error {
                                    self.fail(error.localizedDescription)
                                    return
                                }
                                self.manager = manager
                                self.observe(manager.connection)
                                self.isBusy = false
                                self.statusText = T("Aurora 已写入系统设置的 VPN 列表")
                                guard self.wantsTunnel else { return }
                                do {
                                    try manager.connection.startVPNTunnel()
                                } catch {
                                    self.lastError = error.localizedDescription
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func fail(_ message: String) {
        isBusy = false
        wantsTunnel = false
        lastError = message
        statusText = T("没能写入系统设置")
    }

    private func observe(_ connection: NEVPNConnection?) {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        statusObserver = nil
        guard let connection else { return }
        vpnStatus = connection.status
        applyStatus(connection.status)
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.vpnStatus = connection.status
                self.applyStatus(connection.status)
            }
        }
    }

    private func applyStatus(_ status: NEVPNStatus) {
        switch status {
        case .connected:
            statusText = T("已连上系统 VPN")
        case .connecting, .reasserting:
            statusText = T("正在连接")
        case .disconnecting:
            statusText = T("正在断开")
        case .disconnected:
            statusText = T("系统设置里的 VPN 已关闭")
        case .invalid:
            break
        @unknown default:
            break
        }
    }

    private static var extensionURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/AuroraTunnel.systemextension")
    }
}

private final class SystemExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    let onApproval: () -> Void
    let onFinish: () -> Void
    let onError: (String) -> Void

    init(onApproval: @escaping () -> Void, onFinish: @escaping () -> Void, onError: @escaping (String) -> Void) {
        self.onApproval = onApproval
        self.onFinish = onFinish
        self.onError = onError
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onApproval()
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        onFinish()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        if ns.domain == OSSystemExtensionErrorDomain {
            onError(T("网络扩展没有加载。给 com.cary.aurora 打开 Network Extension，并用带 app-proxy-provider-systemextension 的描述文件签名后再试。"))
            return
        }
        onError(ns.localizedDescription)
    }
}
