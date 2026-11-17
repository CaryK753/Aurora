import Foundation

/// 把解析器中带行号的错误和提示转成现有功能词典的模板。
enum NetworkProxyLocalization {
    static func text(_ message: String) -> String {
        for template in ["自定义规则第 %d 行无效", "第 %d 行节点未导入：格式或协议不支持", "第 %d 个节点协议不支持", "第 %d 个节点依赖代理链，未导入", "第 %d 个节点配置无效，未导入", "第 %d 行节点格式不支持"] {
            let parts = template.components(separatedBy: "%d")
            if message.hasPrefix(parts[0]), message.hasSuffix(parts[1]) {
                let number = message.dropFirst(parts[0].count).dropLast(parts[1].count)
                if let line = Int(number) { return TF(template, line) }
            }
        }
        return T(message)
    }
}
