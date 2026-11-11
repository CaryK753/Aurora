//  HotkeySettingsView.swift
//  Aurora — 全局快捷键：与设置页同层的单层内容页
//
//  每个动作一行：名称 + 当前组合键按钮。点按钮进入录制状态，按下的下一个
//  组合键生效，Esc 取消。冲突时给出行内提示。

import SwiftUI
import Carbon.HIToolbox

struct HotkeySettingsView: View {
    @ObservedObject var hotkeys: HotkeyService

    var body: some View {
        VStack(spacing: 12) {
            introCard
            rowsCard
            tipCard
        }
        .onExitCommand { hotkeys.endRecording() }
    }

    // MARK: 头卡

    private var introCard: some View {
        GlassCard(padding: 16) {
            HStack(spacing: 12) {
                Image(systemName: "command.square.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(AuroraTheme.accentGradient)
                    )
                    .shadow(color: AuroraTheme.accent.opacity(0.3), radius: 5, y: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(T("全局快捷键"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(T("不用打开主面板，随时唤起常用功能。"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
        }
    }

    // MARK: 动作列表

    private var rowsCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                SectionLabel(text: T("快捷键"), symbol: "keyboard")

                ForEach(Array(HotkeyService.Action.allCases.enumerated()), id: \.element.id) { index, action in
                    if index > 0 {
                        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)
                    }
                    row(action)
                }
            }
        }
    }

    private func row(_ action: HotkeyService.Action) -> some View {
        let config = hotkeys.config(for: action)
        let recording = hotkeys.recording == action
        let conflict = hotkeys.recording == nil ? hotkeys.conflict(of: config, excluding: action) : nil

        return HStack(spacing: 10) {
            Image(systemName: action.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(recording ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                if let conflict {
                    Text(TF("与「%@」冲突", conflict.title))
                        .font(.system(size: 8))
                        .foregroundStyle(AuroraTheme.danger)
                }
            }

            Spacer(minLength: 4)

            Button {
                if recording {
                    hotkeys.endRecording()
                } else {
                    hotkeys.startRecording(action)
                }
            } label: {
                Text(recording ? T("按下组合键…") : config.display)
                    .font(.system(size: 10.5, weight: recording ? .semibold : .medium))
                    .foregroundStyle(recording ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4.5)
                    .background {
                        Capsule().fill(recording ? AnyShapeStyle(AuroraTheme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
                    }
                    .overlay {
                        if recording {
                            Capsule().strokeBorder(AuroraTheme.accent, lineWidth: 1.2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(T("点击后按下新的组合键，Esc 取消"))

            Button {
                hotkeys.set(nil, for: action)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(config == action.defaultConfig)
            .opacity(config == action.defaultConfig ? 0.35 : 1)
            .help(T("恢复默认"))
        }
    }

    // MARK: 说明

    private var tipCard: some View {
        GlassCard(padding: 12) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(T("组合键需要带修饰键（⌘ ⌥ ⌃ ⇧）；与系统或其它 App 冲突的组合键可能无法触发。"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}
