import Foundation

/// 域名规则统一大小写、结尾点及子域边界。作者：wwj。
enum InputRuleDomain {
    static func normalize(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, let url = URL(string: text.contains("://") ? text : "https://" + text),
              ["http", "https"].contains(url.scheme), let raw = url.host else { return nil }
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              !host.contains("*"), !host.contains("..") else { return nil }
        return host
    }

    static func matches(host: String, domain: String) -> Bool {
        guard let host = normalize(host), let domain = normalize(domain) else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }
}
