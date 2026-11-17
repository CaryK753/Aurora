import Foundation

enum ShadowrocketConfiguration {
    static func parse(_ text: String, warnings: inout [String]) -> [[String: Any]] {
        var section = ""
        var nodes: [[String: Any]] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { section = line; continue }
            guard section == "[Proxy]", !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            let fields = line[line.index(after: equals)...].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3, let port = Int(fields[2]) else {
                warnings.append("第 \(index + 1) 行节点格式不支持"); continue
            }
            var options: [String: String] = [:]
            for field in fields.dropFirst(3) {
                let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { options[parts[0].lowercased()] = parts[1] }
            }
            let type = fields[0].lowercased()
            var node: [String: Any] = ["name": name, "type": type == "https" ? "http" : type,
                                       "server": fields[1], "port": port]
            if type == "ss" {
                node["cipher"] = options["encrypt-method"] ?? options["method"]
                node["password"] = options["password"]
            } else if type == "vmess" || type == "vless" {
                node["uuid"] = options["uuid"] ?? options["username"]
                if type == "vmess" { node["cipher"] = "auto"; node["alterId"] = Int(options["alterId"] ?? "0") ?? 0 }
            } else {
                node["username"] = options["username"]
                node["password"] = options["password"]
            }
            if type == "https" || type == "trojan" || options["tls"] == "true" { node["tls"] = true }
            if let sni = options["sni"] { node[type == "trojan" ? "sni" : "servername"] = sni }
            if let insecure = options["skip-cert-verify"] { node["skip-cert-verify"] = insecure == "true" }
            if options["obfs"] == "websocket" || options["ws"] == "true" {
                node["network"] = "ws"
                node["ws-opts"] = ["path": options["obfs-uri"] ?? options["ws-path"] ?? "/", "headers": ["Host": options["obfs-host"] ?? ""]]
            } else if let obfs = options["obfs"], ["http", "tls"].contains(obfs), type == "ss" {
                node["plugin"] = "obfs"
                node["plugin-opts"] = ["mode": obfs, "host": options["obfs-host"] ?? ""]
            }
            nodes.append(node)
        }
        warnings.append("Shadowrocket 配置仅导入 Proxy 节点；请在 Aurora 中设置分流规则")
        return nodes
    }
}
