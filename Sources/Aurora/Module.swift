//  Module.swift
//  Aurora — 模块注册表（侧边栏导航与设置页共用）

import SwiftUI

enum AuroraModule: String, CaseIterable, Identifiable {
    case overview, display, pointer, trackpad, keyboard, menu, desktop, clipboard, energy, audio, ai, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return T("概览")
        case .display: return T("显示")
        case .pointer: return T("鼠标")
        case .trackpad: return T("触控板")
        case .keyboard: return T("键盘")
        case .menu: return T("菜单")
        case .desktop: return T("桌面")
        case .clipboard: return T("剪贴板")
        case .energy: return T("节能")
        case .audio: return T("声音")
        case .ai: return T("AI用量")
        case .settings: return T("设置")
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .display: return "display"
        case .pointer: return "computermouse"
        case .trackpad: return "hand.draw"
        case .keyboard: return "keyboard"
        case .menu: return "contextualmenu.and.cursorarrow"
        case .desktop: return "menubar.dock.rectangle"
        case .clipboard: return "doc.on.clipboard"
        case .energy: return "cup.and.saucer.fill"
        case .audio: return "speaker.wave.2.fill"
        case .ai: return "sparkles"
        case .settings: return "gearshape"
        }
    }

    var isToggleable: Bool { self != .overview && self != .settings }

    /// 侧边栏里与设置之间插入分隔线
    var startsGroup: Bool { self == .settings }
}
