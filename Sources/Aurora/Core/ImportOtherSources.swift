import AppKit
import SwiftUI

extension ImportService {
    func sourcePreferences(_ domain: String) -> [String: Any] {
        var result = CFPreferencesCopyMultiple(nil, domain as CFString, kCFPreferencesCurrentUser,
                                              kCFPreferencesAnyHost) as? [String: Any] ?? [:]
        let paths = ["Library/Preferences/\(domain).plist",
                     "Library/Group Containers/\(domain)/Library/Preferences/\(domain).plist"]
        for path in paths {
            let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
            if let data = try? Data(contentsOf: url),
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                result.merge(dict) { _, disk in disk }
            }
        }
        return result
    }

    func flagField(_ id: String, title: String, target: ImportTarget, value: Bool, location: String) -> ImportField {
        ImportField(id: id, title: T(title), detail: id, targetText: T(location), target: target,
                    value: .flag(value), valueText: value ? T("开启") : T("关闭"))
    }

    func boolValue(_ domain: CFString, _ key: String) -> Bool? {
        sourcePreferences(domain as String)[key].flatMap { ($0 as? NSNumber)?.boolValue }
    }

    func rclickSource() -> ImportSource {
        let prefs = sourcePreferences("group.cn.wflixu.RClick")
        var fields: [ImportField] = []
        for item in jsonArray(prefs["RCLICK_ACTIONS"]) where item["id"] as? String == "copy-path" {
            let action = FinderAction(id: "import.rclick.copy-path", title: T("复制路径"), kind: .copyPath,
                                      argument: "", enabled: item["enabled"] as? Bool ?? true)
            fields.append(actionField(action))
        }
        for item in jsonArray(prefs["RCLICK_FILE_TYPES"]) {
            guard let ext = item["ext"] as? String, ["txt", "md", "json", "swift", "html", "css", "js", "csv", "xml", "yaml"].contains(ext),
                  item["template"] == nil else { continue }
            let action = FinderAction(id: "import.rclick.file.\(ext)", title: "\(T("新建文件")) · \(ext)", kind: .newFile,
                                      argument: "\(T("未命名")).\(ext)", enabled: item["enabled"] as? Bool ?? true)
            fields.append(actionField(action))
        }
        return ImportSource(id: "rclick", name: "RClick", subtitle: T("Finder 右键增强"), symbol: "hand.tap.fill",
                            tint: AuroraTheme.danger, fields: fields,
                            note: T("将复制路径和纯文本新建文件项迁入 Aurora，重复导入会更新同一项。含模板、应用参数及删除操作的项目不迁移。"),
                            detected: !prefs.isEmpty || FileManager.default.fileExists(atPath: "/Applications/RClick.app"))
    }

    private func actionField(_ action: FinderAction) -> ImportField {
        ImportField(id: action.id, title: action.title, detail: "RClick", targetText: T("菜单 › Finder 右键"),
                    target: .finderAction(action.id), value: .action(action), valueText: action.enabled ? T("开启") : T("关闭"))
    }

    private func jsonArray(_ value: Any?) -> [[String: Any]] {
        if let data = value as? Data { return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? [] }
        if let string = value as? String { return jsonArray(string.data(using: .utf8)) }
        return value as? [[String: Any]] ?? []
    }

    func energySource() -> ImportSource {
        let prefs = sourcePreferences("info.marcel-dierkes.KeepingYouAwake")
        var fields: [ImportField] = []
        if let value = prefs["info.marcel-dierkes.KeepingYouAwake.ActivateOnLaunch"] as? Bool {
            fields.append(flagField("kya.launch", title: "启动时自动开启", target: .energyOnLaunch,
                                    value: value, location: "节能 › 启动时自动开启"))
        }
        if let allowSleep = prefs["info.marcel-dierkes.KeepingYouAwake.AllowDisplaySleep"] as? Bool {
            fields.append(flagField("kya.display", title: "同时保持屏幕常亮", target: .energyDisplay,
                                    value: !allowSleep, location: "节能 › 同时保持屏幕常亮"))
        }
        return ImportSource(id: "keepingyouawake", name: "KeepingYouAwake", subtitle: T("保持唤醒"), symbol: "cup.and.saucer.fill",
                            tint: AuroraTheme.warn, fields: fields, note: T("导入启动偏好，不会立即开启保持唤醒。"), detected: !prefs.isEmpty)
    }

    func maccySource() -> ImportSource {
        let prefs = sourcePreferences("org.p0deje.Maccy")
        var fields: [ImportField] = []
        if let paused = prefs["ignoreEvents"] as? Bool {
            fields.append(flagField("maccy.enabled", title: "记录剪贴板", target: .clipboardEnabled,
                                    value: !paused, location: "剪贴板 › 记录开关"))
        }
        return ImportSource(id: "maccy", name: "Maccy", subtitle: T("剪贴板"), symbol: "doc.on.clipboard",
                            tint: AuroraTheme.accent, fields: fields,
                            note: T("仅迁移记录开关，不读取剪贴板历史。忽略应用、敏感内容与容量策略不等价，继续保留在 Maccy。"), detected: !prefs.isEmpty)
    }

    func statsSource() -> ImportSource {
        ImportSource(id: "stats", name: "Stats", subtitle: T("系统监控"), symbol: "chart.bar.fill", tint: AuroraTheme.accent,
                     fields: [], note: T("资源采集已内置；菜单栏布局不对应 Aurora，无需迁移。"),
                     detected: !sourcePreferences("eu.exelban.Stats").isEmpty)
    }
}
