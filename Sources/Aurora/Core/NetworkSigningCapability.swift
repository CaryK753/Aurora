import Foundation
import Security

/// 同时检查 Apple 证书信任和网络扩展 entitlement；本地临时签名不算可加载扩展。
enum NetworkSigningCapability {
    static let supportsExtension: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let rule = "anchor apple generic and (certificate leaf[field.1.2.840.113635.100.6.1.9] exists or certificate leaf[field.1.2.840.113635.100.6.1.13] exists or certificate leaf[field.1.2.840.113635.100.6.1.12] exists)"
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let extensions = entitlements["com.apple.developer.networking.networkextension"] as? [String],
              extensions.contains("app-proxy-provider-systemextension") else { return false }
        return Bundle.main.bundleURL.pathExtension == "app"
    }()
}
