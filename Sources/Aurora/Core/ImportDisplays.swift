import AppKit
import SwiftUI

extension ImportService {
    // MARK: - MonitorControl

    /// MonitorControl 把每台显示器的配置存成 `前缀 + 控制码 + (名字厂商型号@显示ID)`。
    /// 显示 ID 每次重启都会变，所以这里先按 ID 精确匹配，再用「厂商+型号」和名字兜底。
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
            let ids = Self.monitorControlParens(for: display, in: all)
            guard !ids.isEmpty else { continue }

            func value(_ prefix: String, _ command: UInt8? = nil) -> Any? {
                for id in ids {
                    // ids 存的是括号里的内容，拼键时要把括号加回来
                    let key = prefix + (command.map { String($0) } ?? "") + "(" + id + ")"
                    if let found = all[key] { return found }
                }
                return nil
            }
            // MonitorControl 对 Float 用字符串存（"0.8594664"），对 Bool/Int 用数字，两种都要认
            func number(_ prefix: String, _ command: UInt8? = nil) -> Double? {
                Self.monitorControlNumber(value(prefix, command))
            }
            func flag(_ prefix: String, _ command: UInt8? = nil) -> Bool? {
                guard let number = Self.monitorControlNumber(value(prefix, command)) else { return nil }
                return number != 0
            }

            func append(_ suffix: String, title: String, detail: String, targetText: String,
                        target: ImportTarget, value importValue: ImportValue, valueText: String) {
                fields.append(ImportField(
                    id: "mc.\(display.id).\(suffix)",
                    title: title,
                    detail: detail,
                    targetText: targetText,
                    target: target,
                    value: importValue,
                    valueText: valueText
                ))
            }

            // 亮度 / 对比 / 音量：MonitorControl 存的就是 0...1
            if let brightness = number("value", 0x10) {
                append("brightness", title: TF("%@ 亮度", display.name),
                       detail: "MonitorControl › value16", targetText: T("显示 › 亮度"),
                       target: .brightness(display.id), value: .number(min(max(brightness, 0), 1)),
                       valueText: Fmt.percent(brightness))
            }
            if let contrast = number("value", 0x12) {
                append("contrast", title: TF("%@ 对比度", display.name),
                       detail: "MonitorControl › value18", targetText: T("显示 › 对比度"),
                       target: .contrast(display.id), value: .number(min(max(contrast, 0), 1)),
                       valueText: Fmt.percent(contrast))
            }
            if let volume = number("value", 0x62) {
                append("volume", title: TF("%@ 音量", display.name),
                       detail: "MonitorControl › value98", targetText: T("显示 › 音量"),
                       target: .displayVolume(display.id), value: .number(min(max(volume, 0), 1)),
                       valueText: Fmt.percent(volume))
            }

            if let name = value("friendlyName") as? String, !name.isEmpty {
                append("name", title: TF("%@ 自定义名称", display.name), detail: "MonitorControl › friendlyName",
                       targetText: T("显示 › 名称"), target: .displayName(display.id),
                       value: .text(name), valueText: name)
            }

            // 高级量程：不同显示器报的 max 差别很大，导入后换算才对得上
            if let maxValue = number("maxDDCOverride", 0x10) ?? number("maxDDC", 0x10), maxValue > 1 {
                append("ddcMax", title: TF("%@ DDC 最大值", display.name), detail: "MonitorControl › maxDDC16",
                       targetText: T("显示 › DDC 量程"), target: .ddcMax(display.id),
                       value: .integer(Int(maxValue)), valueText: "\(Int(maxValue))")
            }
            if let minValue = number("minDDCOverride", 0x10), minValue > 0 {
                append("ddcMin", title: TF("%@ DDC 最小值", display.name), detail: "MonitorControl › minDDCOverride16",
                       targetText: T("显示 › DDC 量程"), target: .ddcMin(display.id),
                       value: .integer(Int(minValue)), valueText: "\(Int(minValue))")
            }
            if let curve = number("curveDDC", 0x10), curve > 0 {
                let multiplier = Self.monitorControlCurve(Int(curve))
                append("curve", title: TF("%@ 亮度曲线", display.name), detail: "MonitorControl › curveDDC16",
                       targetText: T("显示 › 亮度曲线"), target: .ddcCurve(display.id),
                       value: .number(multiplier), valueText: String(format: "×%.1f", multiplier))
            }
            if let invert = flag("invertDDC", 0x10), invert {
                append("invert", title: TF("%@ 反向调光", display.name), detail: "MonitorControl › invertDDC16",
                       targetText: T("显示 › 反向调光"), target: .ddcInvert(display.id),
                       value: .flag(true), valueText: T("开启"))
            }
            if let forceSw = flag("forceSw"), forceSw {
                append("soft", title: TF("%@ 强制软件调光", display.name), detail: "MonitorControl › forceSw",
                       targetText: T("显示 › 软件调光"), target: .displaySoftwareOnly(display.id),
                       value: .flag(true), valueText: T("开启"))
            }
            if let disabled = flag("isDisabled"), disabled {
                append("keyboard", title: TF("%@ 不参与键盘调节", display.name), detail: "MonitorControl › isDisabled",
                       targetText: T("显示 › 键盘调节"), target: .displayKeyboardEnabled(display.id),
                       value: .flag(false), valueText: T("关闭"))
            }
            if let mute = flag("enableMuteUnmute"), mute {
                append("mute", title: TF("%@ 静音联动", display.name), detail: "MonitorControl › enableMuteUnmute",
                       targetText: T("显示 › 静音联动"), target: .displayMuteAtZero(display.id),
                       value: .flag(true), valueText: T("开启"))
            }
            if let hideOSD = flag("hideOsd"), hideOSD {
                append("osd", title: TF("%@ 隐藏 OSD", display.name), detail: "MonitorControl › hideOsd",
                       targetText: T("显示 › OSD"), target: .displayHideOSD(display.id),
                       value: .flag(true), valueText: T("开启"))
            }
        }

        // 全局行为
        if let smooth = Self.monitorControlNumber(all["disableSmoothBrightness"]) {
            let enabled = smooth == 0
            fields.append(ImportField(
                id: "mc.smooth", title: T("平滑亮度过渡"), detail: "MonitorControl › disableSmoothBrightness",
                targetText: T("显示 › 平滑过渡"), target: .smoothBrightness,
                value: .flag(enabled), valueText: enabled ? T("开启") : T("关闭")
            ))
        }
        if let combined = Self.monitorControlNumber(all["disableCombinedBrightness"]) {
            let enabled = combined == 0
            fields.append(ImportField(
                id: "mc.combined", title: T("软件调光（硬件到底后继续压暗）"), detail: "MonitorControl › disableCombinedBrightness",
                targetText: T("显示 › 软件调光"), target: .combinedDimming,
                value: .flag(enabled), valueText: enabled ? T("开启") : T("关闭")
            ))
        }
        if let sync = Self.monitorControlNumber(all["enableBrightnessSync"]) {
            let enabled = sync != 0
            fields.append(ImportField(
                id: "mc.sync", title: T("所有显示器同步亮度"), detail: "MonitorControl › enableBrightnessSync",
                targetText: T("显示 › 多屏同步"), target: .syncDisplays,
                value: .flag(enabled), valueText: enabled ? T("开启") : T("关闭")
            ))
        }
        if let multi = Self.monitorControlNumber(all["multiKeyboardBrightness"]) {
            let enabled = multi == 0
            fields.append(ImportField(
                id: "mc.followMouse", title: T("亮度键跟随鼠标所在屏"), detail: "MonitorControl › multiKeyboardBrightness",
                targetText: T("显示 › 跟随鼠标"), target: .followMouseDisplay,
                value: .flag(enabled), valueText: enabled ? T("开启") : T("关闭")
            ))
        }
        if let startup = Self.monitorControlNumber(all["startupAction"]) {
            let enabled = startup == 1
            fields.append(ImportField(
                id: "mc.startup", title: T("启动时恢复上次亮度"), detail: "MonitorControl › startupAction",
                targetText: T("显示 › 启动恢复"), target: .restoreBrightness,
                value: .flag(enabled), valueText: enabled ? T("开启") : T("关闭")
            ))
        }

        let note: String
        if fields.isEmpty {
            note = T("已安装，但没有找到与当前显示器匹配的配置。")
        } else {
            note = T("读取 MonitorControl 每台显示器的亮度/对比度/音量、DDC 量程、曲线与行为开关；导入后立即按新量程换算。")
        }

        return ImportSource(
            id: "monitorcontrol", name: "MonitorControl", subtitle: T("显示器亮度与行为"),
            symbol: "sun.max.fill", tint: AuroraTheme.warn,
            fields: fields, note: note, detected: true
        )
    }

    /// MonitorControl 的数字可能是 NSNumber，也可能是字符串
    static func monitorControlNumber(_ any: Any?) -> Double? {
        if let number = any as? NSNumber { return number.doubleValue }
        if let text = any as? String { return Double(text) }
        return nil
    }

    /// MonitorControl 的曲线码 → 乘数（与他们 getCurveMultiplier 一致）
    static func monitorControlCurve(_ code: Int) -> Double {
        switch code {
        case 1: return 0.6
        case 2: return 0.7
        case 3: return 0.8
        case 4: return 0.9
        case 6: return 1.3
        case 7: return 1.5
        case 8: return 1.7
        case 9: return 1.88
        default: return 1.0
        }
    }

    /// 找出属于这台显示器的所有 prefsId 括号片段
    static func monitorControlParens(for display: DisplayItem, in all: [String: Any]) -> [String] {
        let vendor = CGDisplayVendorNumber(display.id)
        let model = CGDisplayModelNumber(display.id)
        let vendorModel = "\(vendor)\(model)@"
        let strippedNames = [display.name, display.nativeName]
            .map { $0.filter { !$0.isWhitespace }.lowercased() }
            .filter { !$0.isEmpty }

        var ids: [String] = []
        for key in all.keys {
            guard let open = key.lastIndex(of: "("), let close = key.lastIndex(of: ")"), open < close else { continue }
            let paren = String(key[key.index(after: open)..<close])
            guard !ids.contains(paren) else { continue }

            if paren.hasSuffix("@\(display.id)") { ids.append(paren); continue }
            if paren.contains(vendorModel) { ids.append(paren); continue }
            if strippedNames.contains(where: { paren.lowercased().hasPrefix($0) }) { ids.append(paren); continue }
        }
        return ids
    }
}
