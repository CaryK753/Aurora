import AppKit
import SwiftUI

extension ImportService {
    // MARK: - MonitorControl

    func monitorControlSource(displays: [DisplayItem]) -> ImportSource {
        let domain = "app.monitorcontrol.MonitorControl" as CFString
        let installed = FileManager.default.fileExists(
            atPath: NSString(string: "~/Library/Preferences/app.monitorcontrol.MonitorControl.plist").expandingTildeInPath
        )
        guard installed, let all = CFPreferencesCopyMultiple(nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] else {
            return ImportSource(
                id: "monitorcontrol", name: "MonitorControl", subtitle: T("显示器亮度"), symbol: "sun.max.fill",
                tint: AuroraTheme.warn, fields: [], note: nil, detected: false
            )
        }

        var fields: [ImportField] = []
        for display in displays {
            let suffix = "@\(display.id))"
            let key = all.keys.first { $0.hasPrefix("value16(") && $0.hasSuffix(suffix) }
            guard let key, let number = all[key] as? NSNumber else { continue }
            let value = min(max(number.doubleValue, 0), 1)
            fields.append(
                ImportField(
                    id: "mc.\(display.id)",
                    title: TF("%@ 亮度", display.name),
                    detail: "MonitorControl › \(key)",
                    targetText: T("显示 › 亮度"),
                    target: .brightness(display.id),
                    value: .number(value),
                    valueText: Fmt.percent(value)
                )
            )
        }

        return ImportSource(
            id: "monitorcontrol", name: "MonitorControl", subtitle: T("显示器亮度"),
            symbol: "sun.max.fill", tint: AuroraTheme.warn,
            fields: fields,
            note: fields.isEmpty ? T("已安装，但没有找到与当前显示器匹配的亮度记录。") : T("读取 MonitorControl 为每台显示器保存的亮度值。"),
            detected: true
        )
    }

}
