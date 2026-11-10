import Foundation

/// 仅接受 Aurora 能准确表达的无条件／鼠标通用配置。
enum ImportParsing {
    static func linearMouse(_ schemes: [[String: Any]]) -> (reverse: Bool?, shiftHorizontal: Bool?) {
        var reverse: Bool?
        var horizontal: Bool?
        for scheme in schemes {
            if let condition = scheme["if"] {
                guard let object = condition as? [String: Any], object.count == 1,
                      let device = object["device"] as? [String: Any], device.count == 1,
                      device["category"] as? String == "mouse" else { continue }
            }
            guard let scrolling = scheme["scrolling"] as? [String: Any] else { continue }
            let rawReverse = scrolling["reverse"]
            if let flag = rawReverse as? Bool { reverse = flag }
            else if let axes = rawReverse as? [String: Any], let flag = axes["vertical"] as? Bool { reverse = flag }
            let rawModifiers = scrolling["modifiers"] as? [String: Any]
            let modifiers = rawModifiers?["vertical"] as? [String: Any] ?? rawModifiers
            if let shift = modifiers?["shift"] as? [String: Any], let type = shift["type"] as? String {
                if type == "alterOrientation" { horizontal = true }
                else if type == "ignore" || type == "preventDefault" { horizontal = false }
            }
        }
        return (reverse, horizontal)
    }
}
