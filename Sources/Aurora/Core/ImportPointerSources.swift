import AppKit
import SwiftUI

extension ImportService {
    func mosSource() -> ImportSource {
        let values = sourcePreferences("com.caldis.Mos")
        let enabled = (values["reverse"] as? NSNumber)?.boolValue
        let vertical = (values["reverseVertical"] as? NSNumber)?.boolValue ?? true
        var fields: [ImportField] = []
        if let enabled {
            fields.append(flagField("mos.reverse", title: "反转滚动方向", target: .invertScroll,
                                    value: enabled && vertical, location: "鼠标 › 反转滚动方向"))
        }
        return ImportSource(id: "mos", name: "Mos", subtitle: T("平滑滚动"), symbol: "computermouse.fill",
                            tint: AuroraTheme.ok, fields: fields,
                            note: T("导入垂直反转开关。Mos 的平滑速度、横向独立反转及按应用规则与 Aurora 不等价，保留原配置，不进行近似换算。"),
                            detected: !values.isEmpty)
    }

    func linearMouseSource() -> ImportSource {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/linearmouse/linearmouse.json")
        let exists = FileManager.default.fileExists(atPath: url.path)
        var source = ImportSource(id: "linearmouse", name: "LinearMouse", subtitle: T("指针与滚动"),
                                  symbol: "cursorarrow.motionlines", tint: AuroraTheme.accent, fields: [],
                                  note: nil, detected: exists)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schemes = root["schemes"] as? [[String: Any]] else {
            if exists { source.note = T("配置无法读取或格式不支持，请检查权限与文件格式。") }
            return source
        }
        let values = ImportParsing.linearMouse(schemes)
        if let reverse = values.reverse {
            source.fields.append(flagField("lm.reverse", title: "反转滚动方向", target: .invertScroll,
                                           value: reverse, location: "鼠标 › 反转滚动方向"))
        }
        if let horizontal = values.shiftHorizontal {
            source.fields.append(flagField("lm.shift", title: "Shift 横向滚动", target: .shiftHorizontal,
                                           value: horizontal, location: "鼠标 › Shift 横向滚动"))
        }
        source.note = T("仅迁移全局或仅匹配鼠标的方向与 Shift 设置；设备、应用专用规则不合并。HID 速度与关闭原生加速无法等价迁移，保留原配置。")
        return source
    }
}

