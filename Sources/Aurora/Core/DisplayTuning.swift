//  DisplayTuning.swift
//  Aurora — 每台显示器的 DDC 调校（复刻 MonitorControl 的 per-display 高级选项）
//
//  MonitorControl 把这些参数按「显示器 + 控制码」存进 UserDefaults；
//  Aurora 用一份 Codable 字典按稳定的显示器 key（厂商-型号-序列号）保存，
//  重连、换口、重启都不会丢。导入 MonitorControl 配置时也写进这里。

import Combine
import CoreGraphics
import Foundation

/// 可调的 DDC 通道（VCP 码与 MonitorControl 一致）
enum DisplayChannel: String, CaseIterable, Identifiable, Codable {
    case brightness, contrast, volume

    var id: String { rawValue }

    var vcp: UInt8 {
        switch self {
        case .brightness: return 0x10
        case .contrast: return 0x12
        case .volume: return 0x62
        }
    }

    var title: String {
        switch self {
        case .brightness: return T("亮度")
        case .contrast: return T("对比度")
        case .volume: return T("音量")
        }
    }
}

/// 单台显示器的调校参数
struct DisplayTuning: Codable, Equatable {
    /// 覆盖 DDC 最小值（默认 0），用于显示器在 0 处会黑屏的情况
    var minValue: [String: Int] = [:]
    /// 覆盖 DDC 最大值（0 = 自动读显示器报告的 max）
    var maxValue: [String: Int] = [:]
    var invert: [String: Bool] = [:]
    /// 1.0 线性；<1 低亮度更细腻；>1 低亮度更陡
    var curve: [String: Double] = [:]
    /// 控制码重映射（十六进制，逗号分隔），个别显示器要换码才响应
    var remap: [String: String] = [:]
    var customName: String = ""
    /// 强制软件调光（DDC 不可用或不想动硬件时）
    var softwareOnly: Bool = false
    /// 避开 gamma 表，改用叠加遮罩（与 f.lux 之类冲突时）
    var avoidGamma: Bool = false
    var keyboardEnabled: Bool = true
    var hideOSD: Bool = false
    /// 音量为 0 时同时写 DDC 静音码
    var muteAtZero: Bool = false

    func max(_ channel: DisplayChannel) -> Int { maxValue[channel.rawValue] ?? 0 }
    func min(_ channel: DisplayChannel) -> Int { minValue[channel.rawValue] ?? 0 }
    func isInverted(_ channel: DisplayChannel) -> Bool { invert[channel.rawValue] ?? false }
    func curveValue(_ channel: DisplayChannel) -> Double { curve[channel.rawValue] ?? 1 }
    func remapCodes(_ channel: DisplayChannel) -> [UInt8] {
        (remap[channel.rawValue] ?? "")
            .split(separator: ",")
            .compactMap { UInt8($0.trimmingCharacters(in: .whitespaces), radix: 16) }
            .filter { $0 != 0 }
    }
}

/// 按显示器保存调校参数
@MainActor
final class DisplayTuningStore: ObservableObject {
    @Published private(set) var tunings: [String: DisplayTuning] = [:]

    private let key = "display.tunings"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([String: DisplayTuning].self, from: data) {
            tunings = saved
        }
    }

    /// 稳定的显示器 key：换 USB 口 / 重启后 CGDirectDisplayID 会变，厂商型号序列号不会
    nonisolated static func key(for id: CGDirectDisplayID) -> String {
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        return "\(vendor)-\(model)-\(serial)"
    }

    func tuning(for id: CGDirectDisplayID) -> DisplayTuning {
        tunings[Self.key(for: id)] ?? DisplayTuning()
    }

    func update(_ id: CGDirectDisplayID, _ mutate: (inout DisplayTuning) -> Void) {
        var tuning = tuning(for: id)
        mutate(&tuning)
        tunings[Self.key(for: id)] = tuning
        persist()
    }

    func reset(_ id: CGDirectDisplayID) {
        tunings.removeValue(forKey: Self.key(for: id))
        persist()
    }

    /// 导入 MonitorControl 配置时整块替换
    func replaceAll(_ values: [String: DisplayTuning]) {
        tunings.merge(values) { _, new in new }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(tunings) { defaults.set(data, forKey: key) }
    }
}
