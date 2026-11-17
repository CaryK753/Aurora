import Foundation
import Security
import SystemConfiguration

/// 使用系统配置事务保存代理；备份跨应用重启保留。
enum SystemProxyPreferences {
    private static let backupKey = "network.systemProxy.backup"
    static var hasBackup: Bool { UserDefaults.standard.dictionary(forKey: backupKey) != nil }

    static func apply(host: String, port: Int, socks: Bool) throws {
        try apply { proxyDictionary(original: $0, host: host, port: port, socks: socks) }
    }

    static func applyDirect() throws {
        try apply { directDictionary(original: $0) }
    }

    private static func apply(_ build: ([String: Any]) -> [String: Any]) throws {
        try transaction { preferences in
            let defaults = UserDefaults.standard
            guard !hasBackup else { throw failure("请先恢复原代理配置，再应用新节点") }
            guard let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
                throw failure("无法读取网络服务")
            }
            var backup: [String: Any] = [:]
            for service in services where SCNetworkServiceGetEnabled(service) {
                guard let serviceID = SCNetworkServiceGetServiceID(service) else { continue }
                let id = serviceID as String
                let path = "/NetworkServices/\(id)/Proxies"
                let original = SCPreferencesPathGetValue(preferences, path as CFString) as? [String: Any]
                let applied = build(original ?? [:])
                backup[path] = ["original": original ?? [:], "existed": original != nil, "applied": applied]
                guard SCPreferencesPathSetValue(preferences, path as CFString, applied as CFDictionary) else {
                    throw failure("无法写入系统代理")
                }
            }
            guard !backup.isEmpty else { throw failure("没有可配置的网络服务") }
            // 先持久保存恢复信息，即使程序退出也能恢复。
            defaults.set(backup, forKey: backupKey)
        }
    }

    static func restore() throws {
        try transaction { preferences in
            guard let backup = UserDefaults.standard.dictionary(forKey: backupKey) else { return }
            for (path, raw) in backup {
                guard let item = raw as? [String: Any],
                      let applied = item["applied"] as? NSDictionary,
                      let original = item["original"] as? [String: Any] else {
                    throw failure("系统代理备份无效")
                }
                let current = SCPreferencesPathGetValue(preferences, path as CFString) as NSDictionary?
                // 已删除的网络服务无需重建。
                let servicePath = String(path.dropLast("/Proxies".count))
                guard SCPreferencesPathGetValue(preferences, servicePath as CFString) != nil else { continue }
                guard canRestore(current: current, applied: applied, original: original as NSDictionary, existed: item["existed"] as? Bool == true) else {
                    throw failure("代理已被其他程序修改，请在系统设置中检查后重试")
                }
                if item["existed"] as? Bool == true {
                    guard SCPreferencesPathSetValue(preferences, path as CFString, original as CFDictionary) else {
                        throw failure("无法恢复原代理配置")
                    }
                } else if current != nil {
                    guard SCPreferencesPathRemoveValue(preferences, path as CFString) else {
                        throw failure("无法恢复原代理配置")
                    }
                }
            }
        }
        UserDefaults.standard.removeObject(forKey: backupKey)
    }

    static func canRestore(current: NSDictionary?, applied: NSDictionary, original: NSDictionary, existed: Bool) -> Bool {
        current == applied || (existed ? current == original : current == nil)
    }

    static func proxyDictionary(original: [String: Any], host: String, port: Int, socks: Bool) -> [String: Any] {
        var result = directDictionary(original: original)
        for prefix in socks ? ["SOCKS"] : ["HTTP", "HTTPS"] {
            result["\(prefix)Enable"] = 1
            result["\(prefix)Proxy"] = host
            result["\(prefix)Port"] = port
        }
        return result
    }

    static func directDictionary(original: [String: Any]) -> [String: Any] {
        var result = original
        for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable", "FTPEnable", "GopherEnable", "RTSPEnable"] {
            result[key] = 0
        }
        return result
    }

    private static func transaction(_ body: (SCPreferences) throws -> Void) throws {
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
              let authorization else { throw failure("无法请求系统网络授权") }
        defer { AuthorizationFree(authorization, []) }
        guard let preferences = SCPreferencesCreateWithAuthorization(nil, "Aurora System Proxy" as CFString, nil, authorization) else {
            throw failure("无法打开系统网络配置")
        }
        guard SCPreferencesLock(preferences, true) else { throw failure("无法锁定系统网络配置") }
        defer { SCPreferencesUnlock(preferences) }
        try body(preferences)
        guard SCPreferencesCommitChanges(preferences) else { throw failure("系统代理保存失败，请检查管理员授权") }
        guard SCPreferencesApplyChanges(preferences) else { throw failure("系统代理生效失败，请重试恢复") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Aurora.SystemProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: T(message)])
    }
}
