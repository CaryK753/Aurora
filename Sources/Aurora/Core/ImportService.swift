//  ImportService.swift
//  Aurora — 从参考项目一键导入配置
//  支持：Mos / LinearMouse / MonitorControl / RClick（Stats 无同类设置，仅做检测提示）

import AppKit
import Combine
import CoreGraphics
import SwiftUI

enum ImportTarget: Hashable {
    case pointerSpeed
    case pointerAcceleration
    case scrollSpeed
    case invertScroll
    case brightness(CGDirectDisplayID)
    case finderAction(String)
    case shiftHorizontal
    case clipboardEnabled
    case energyOnLaunch
    case energyDisplay
}

enum ImportValue {
    case number(Double)
    case flag(Bool)
    case action(FinderAction)
}

struct ImportField: Identifiable {
    let id: String
    var title: String
    var detail: String
    var targetText: String
    var target: ImportTarget
    var value: ImportValue
    var valueText: String
    var selected: Bool = true
}

struct ImportSource: Identifiable {
    let id: String
    var name: String
    var subtitle: String
    var symbol: String
    var tint: Color
    var fields: [ImportField]
    var note: String?
    var detected: Bool
}

@MainActor
final class ImportService: ObservableObject {
    @Published private(set) var sources: [ImportSource] = []
    @Published private(set) var isScanning = false
    @Published private(set) var resultMessage: String?

    var selectableCount: Int {
        sources.reduce(0) { $0 + $1.fields.filter(\.selected).count }
    }

    // MARK: - 扫描

    func scan(displays: [DisplayItem]) {
        isScanning = true
        var result: [ImportSource] = []
        result.append(mosSource())
        result.append(linearMouseSource())
        result.append(monitorControlSource(displays: displays))
        result.append(rclickSource())
        result.append(energySource())
        result.append(maccySource())
        result.append(statsSource())
        var selectedTargets = Set<ImportTarget>()
        for sourceIndex in result.indices {
            for fieldIndex in result[sourceIndex].fields.indices {
                let target = result[sourceIndex].fields[fieldIndex].target
                if !selectedTargets.insert(target).inserted { result[sourceIndex].fields[fieldIndex].selected = false }
            }
        }
        sources = result
        isScanning = false
    }

    func toggle(_ fieldID: String, in sourceID: String, selected: Bool) {
        guard let sourceIndex = sources.firstIndex(where: { $0.id == sourceID }),
              let fieldIndex = sources[sourceIndex].fields.firstIndex(where: { $0.id == fieldID })
        else { return }
        sources[sourceIndex].fields[fieldIndex].selected = selected
    }

    func toggleSource(_ sourceID: String, selected: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        for fieldIndex in sources[index].fields.indices {
            sources[index].fields[fieldIndex].selected = selected
        }
    }

    func setResultMessage(_ value: String) { resultMessage = value }

    // 各来源解析见 ImportPointerSources / ImportOtherSources / ImportDisplays。
}
