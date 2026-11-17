import Foundation

/// 解析客户端分享链接；错误不回显原链接，防止泄露订阅凭据。
enum ProxyURIParser {
    static func parse(_ link: String) throws -> [String: Any] {
        guard let separator = link.range(of: "://") else { throw ProxyFailure("节点链接无效") }
        let scheme = String(link[..<separator.lowerBound]).lowercased()
        if scheme == "ssr" { return try shadowsocksR(String(link[separator.upperBound...])) }
        if scheme == "vmess" { return try vmess(String(link[separator.upperBound...])) }
        var link = link
        if scheme == "ss" {
            let body = String(link[separator.upperBound...]).components(separatedBy: "#")[0]
            if !body.contains("@"), let decoded = SubscriptionParser.decodeBase64(body) {
                let fragment = link.components(separatedBy: "#").dropFirst().joined(separator: "#")
                guard let at = decoded.lastIndex(of: "@") else { throw ProxyFailure("Shadowsocks 凭据无效") }
                let credentials = Data(decoded[..<at].utf8).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                link = "ss://\(credentials)@\(decoded[decoded.index(after: at)...])" + (fragment.isEmpty ? "" : "#\(fragment)")
            }
        }
        guard let components = URLComponents(string: link), let host = components.host, let port = components.port else {
            throw ProxyFailure("节点地址无效")
        }
        let query = Dictionary(components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { _, new in new })
        var node: [String: Any] = ["name": components.fragment ?? host, "server": host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), "port": port]
        let user = components.user ?? ""
        switch scheme {
        case "ss":
            let credentials = components.password.map { "\(user):\($0)" } ?? SubscriptionParser.decodeBase64(user) ?? ""
            guard let colon = credentials.firstIndex(of: ":") else { throw ProxyFailure("Shadowsocks 凭据无效") }
            node["type"] = "ss"
            node["cipher"] = String(credentials[..<colon])
            node["password"] = String(credentials[credentials.index(after: colon)...])
            if let plugin = query["plugin"] {
                let fields = plugin.components(separatedBy: ";")
                guard let name = fields.first, ["obfs-local", "v2ray-plugin"].contains(name) else {
                    throw ProxyFailure("Shadowsocks 插件不支持")
                }
                node["plugin"] = name == "obfs-local" ? "obfs" : name
                var options: [String: Any] = [:]
                for field in fields.dropFirst() {
                    let pair = field.split(separator: "=", maxSplits: 1).map(String.init)
                    guard !pair.isEmpty else { continue }
                    let key = pair[0] == "obfs" ? "mode" : pair[0].replacingOccurrences(of: "obfs-", with: "")
                    options[key] = pair.count == 2 ? pair[1] as Any : true
                }
                node["plugin-opts"] = options
            }
        case "http", "https", "socks", "socks5":
            node["type"] = scheme.hasPrefix("http") ? "http" : "socks5"
            if !user.isEmpty { node["username"] = user }
            if let password = components.password { node["password"] = password }
            if scheme == "https" { node["tls"] = true }
        case "trojan", "vless", "hysteria2", "hy2", "tuic":
            node["type"] = scheme == "hy2" ? "hysteria2" : scheme
            if scheme == "vless" || scheme == "tuic" {
                node["uuid"] = user
                if let flow = query["flow"], !flow.isEmpty { node["flow"] = flow }
                if scheme == "tuic" { node["password"] = components.password ?? "" }
            } else { node["password"] = user + (components.password.map { ":\($0)" } ?? "") }
            if scheme == "trojan" || scheme == "tuic" || scheme == "hy2" || scheme == "hysteria2" { node["tls"] = true }
            if scheme == "hy2" || scheme == "hysteria2" {
                if let obfs = query["obfs"] { node["obfs"] = obfs }
                if let password = query["obfs-password"] { node["obfs-password"] = password }
            }
        default: throw ProxyFailure("节点协议不支持")
        }
        try transport(query, node: &node)
        return node
    }

    private static func vmess(_ encoded: String) throws -> [String: Any] {
        guard let text = SubscriptionParser.decodeBase64(encoded), let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = value["add"] as? String else { throw ProxyFailure("VMess 链接无效") }
        let port = (value["port"] as? Int) ?? Int(value["port"] as? String ?? "") ?? 0
        var node: [String: Any] = ["name": value["ps"] as? String ?? host, "type": "vmess", "server": host,
                                   "port": port, "uuid": value["id"] as? String ?? "", "cipher": value["scy"] as? String ?? "auto",
                                   "alterId": (value["aid"] as? Int) ?? Int(value["aid"] as? String ?? "") ?? 0]
        var query: [String: String] = [:]
        for (source, target) in [("net", "type"), ("path", "path"), ("host", "host"), ("sni", "sni"), ("tls", "security")] {
            query[target] = value[source] as? String
        }
        if query["type"] == "grpc" { query["serviceName"] = value["path"] as? String }
        try transport(query, node: &node)
        return node
    }

    private static func transport(_ query: [String: String], node: inout [String: Any]) throws {
        if let security = query["security"], ["tls", "reality"].contains(security) { node["tls"] = true }
        if let sni = query["sni"] ?? query["peer"] ?? query["serverName"], !sni.isEmpty {
            node[["vmess", "vless"].contains(node["type"] as? String ?? "") ? "servername" : "sni"] = sni
        }
        if let insecure = query["allowInsecure"] ?? query["insecure"] { node["skip-cert-verify"] = ["1", "true"].contains(insecure) }
        if let alpn = query["alpn"] { node["alpn"] = alpn.components(separatedBy: ",") }
        if let fp = query["fp"] { node["client-fingerprint"] = fp }
        if query["security"] == "reality" {
            guard let key = query["pbk"], !key.isEmpty else { throw ProxyFailure("Reality 公钥缺失") }
            node["reality-opts"] = ["public-key": key, "short-id": query["sid"] ?? ""]
        }
        switch query["type"] ?? "tcp" {
        case "", "tcp", "none": break
        case "ws":
            node["network"] = "ws"
            node["ws-opts"] = ["path": query["path"] ?? "/", "headers": ["Host": query["host"] ?? ""]]
        case "grpc":
            node["network"] = "grpc"
            node["grpc-opts"] = ["grpc-service-name": query["serviceName"] ?? ""]
        case "h2":
            node["network"] = "h2"
            node["h2-opts"] = ["path": query["path"] ?? "/", "host": [query["host"] ?? ""]]
        default: throw ProxyFailure("节点传输方式不支持")
        }
    }

    private static func shadowsocksR(_ encoded: String) throws -> [String: Any] {
        guard let text = SubscriptionParser.decodeBase64(encoded) else { throw ProxyFailure("SSR 链接无效") }
        let parts = text.components(separatedBy: "/?")
        let fields = parts[0].components(separatedBy: ":")
        guard fields.count == 6, let port = Int(fields[1]), let password = SubscriptionParser.decodeBase64(fields[5]) else {
            throw ProxyFailure("SSR 链接无效")
        }
        let query = URLComponents(string: "https://subscription.invalid/?" + (parts.count > 1 ? parts[1] : ""))?.queryItems ?? []
        let options = Dictionary(query.map { ($0.name, SubscriptionParser.decodeBase64($0.value ?? "") ?? "") }, uniquingKeysWith: { _, new in new })
        return ["name": options["remarks"] ?? fields[0], "type": "ssr", "server": fields[0], "port": port,
                "password": password, "protocol": fields[2], "cipher": fields[3], "obfs": fields[4],
                "protocol-param": options["protoparam"] ?? "", "obfs-param": options["obfsparam"] ?? ""]
    }
}
