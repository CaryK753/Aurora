//  DisplayView.swift
//  Aurora — 显示器设置

import SwiftUI

struct DisplayView: View {
    @ObservedObject var service: DisplayService
    @ObservedObject var tunings: DisplayTuningStore
    @ObservedObject var permissions: PermissionService
    @ObservedObject var state: AppState
    @State private var pattern: ScreenPattern = .white

    init(state: AppState) {
        self.state = state
        self.service = state.display
        self.tunings = state.display.tunings
        self.permissions = state.permissions
    }

    var body: some View {
        VStack(spacing: 12) {
            if service.displays.isEmpty {
                GlassCard {
                    Text(T("未检测到显示器"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(service.displays) { display in
                    displayCard(display)
                }
            }
            DisplayBehaviorCard(service: service, permissions: permissions)
            screenTestCard
            if let primary = service.displays.first(where: { $0.isMain }) ?? service.displays.first {
                infoCard(primary)
            }
            restoreCard
            tipCard
        }
    }

    private func displayCard(_ display: DisplayItem) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    IconBadge(symbol: display.isBuiltIn ? "laptopcomputer" : "display", color: AuroraTheme.ok, size: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(display.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Text("\(display.pixelLabel) · \(Int(display.refresh.rounded()))Hz\(display.isBuiltIn ? " · " + T("内建") : "")")
                            .font(.system(size: 9.5, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    if display.isMain {
                        Text(T("主屏"))
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(AuroraTheme.accentGradient))
                    }
                }

                if display.hasBrightness {
                    SliderRow(
                        symbol: brightnessSymbol(display.brightness),
                        title: T("亮度"),
                        value: Binding(
                            get: { display.brightness },
                            set: { service.setBrightness($0, for: display.id) }
                        ),
                        displayText: Fmt.percent(display.brightness)
                    )
                    brightnessPresets(display)
                }

                if display.hasVolume {
                    HStack(spacing: 6) {
                        SliderRow(
                            symbol: display.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            title: T("音量"),
                            value: Binding(
                                get: { display.volume },
                                set: { service.setVolume($0, for: display.id) }
                            ),
                            displayText: Fmt.percent(display.volume),
                            tint: LinearGradient(colors: [AuroraTheme.ok, AuroraTheme.accent], startPoint: .leading, endPoint: .trailing)
                        )
                        Button {
                            service.toggleMute(for: display.id)
                        } label: {
                            Image(systemName: display.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(display.volume < 0.01 ? AnyShapeStyle(AuroraTheme.warn) : AnyShapeStyle(Color.secondary))
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        .help(T("显示器静音"))
                    }
                }

                if display.hasContrast {
                    SliderRow(
                        symbol: "circle.lefthalf.filled",
                        title: T("对比"),
                        value: Binding(
                            get: { display.contrast },
                            set: { service.setContrast($0, for: display.id) }
                        ),
                        displayText: Fmt.percent(display.contrast),
                        tint: LinearGradient(colors: [AuroraTheme.accent, AuroraTheme.accent.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
                    )
                }

                if !display.modes.isEmpty {
                    resolutionRow(display)
                }

                if display.hasBrightness || !display.isBuiltIn {
                    DisplayAdvancedSettings(service: service, tunings: tunings, display: display)
                }

                if !display.hasBrightness && !display.hasVolume {
                    Text(T("该显示器未提供 DDC 通道；可在「高级」里开启强制软件调光"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 屏幕检测

    private var screenTestCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("屏幕检测"), symbol: "display.2")
                    Spacer()
                    Text(T("全屏 · ESC 退出"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                    ForEach(ScreenPattern.allCases) { item in
                        patternChip(item)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                    Text(T(pattern.hint))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(TF("%d/%d", (ScreenPattern.allCases.firstIndex(of: pattern) ?? 0) + 1, ScreenPattern.allCases.count))
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 6) {
                    Button {
                        launch(nil)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8, weight: .bold))
                            Text(service.displays.count > 1 ? T("所有显示器") : T("开始检测"))
                        }
                    }
                    .buttonStyle(SoftButtonStyle(prominent: true))

                    if service.displays.count > 1 {
                        Menu {
                            Button(T("所有显示器")) { launch(nil) }
                            Divider()
                            ForEach(service.displays) { display in
                                Button(display.name) { launch(display.id) }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(T("单屏"))
                                    .font(.system(size: 10.5, weight: .medium))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 6.5, weight: .bold))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }

                    Spacer()

                    Text(T("← → 切换"))
                        .font(.system(size: 8.5, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func patternChip(_ item: ScreenPattern) -> some View {
        let active = pattern == item
        return Button {
            pattern = item
        } label: {
            VStack(spacing: 3) {
                if let swatch = item.swatch {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(swatch)
                        .frame(height: 14)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.6)
                        }
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 10, weight: .medium))
                        .frame(height: 14)
                }
                Text(T(item.title))
                    .font(.system(size: 8.5, weight: active ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(Color.secondary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background {
               // 选中只描淡蓝边，不上整块蓝色填充，色卡本身才是主角
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? AnyShapeStyle(AuroraTheme.accent.opacity(0.10)) : AnyShapeStyle(Color.primary.opacity(0.05)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        active ? AuroraTheme.accent.opacity(0.85) : Color.primary.opacity(0.08),
                        lineWidth: active ? 1.3 : 0.6
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private func launch(_ target: CGDirectDisplayID?) {
        state.dismissMainPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            state.screenTest.start(pattern: pattern, target: target)
        }
    }

    private func resolutionRow(_ display: DisplayItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.inset.filled")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(T("分辨率"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 32, alignment: .leading)

            Spacer(minLength: 0)

            Menu {
                ForEach(display.modes) { mode in
                    Button {
                        let succeeded = service.apply(mode: mode, for: display.id)
                        state.showToast(succeeded ? TF("已切换到 %@", mode.label) : T("分辨率切换失败"),
                                        symbol: succeeded ? "rectangle.inset.filled" : "exclamationmark.triangle")
                    } label: {
                        if mode.isCurrent {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentModeLabel(display))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func currentModeLabel(_ display: DisplayItem) -> String {
        if let current = display.modes.first(where: { $0.isCurrent }) {
            return current.label
        }
        return display.resolutionLabel
    }

    private func brightnessSymbol(_ value: Double) -> String {
        switch value {
        case ..<0.15: return "sun.min.fill"
        case ..<0.7: return "sun.max.fill"
        default: return "sun.max.fill"
        }
    }

    private func infoCard(_ display: DisplayItem) -> some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: T("显示器信息"), symbol: "info.circle")
                infoRow(T("原生像素"), display.pixelLabel)
                infoRow(T("当前缩放"), display.resolutionLabel)
                infoRow(T("刷新率"), TF("%d Hz", Int(display.refresh.rounded())))
                infoRow(T("亮度通道"), display.isBuiltIn ? T("系统 · DisplayServices") : (display.softwareOnly ? T("软件 · Gamma") : (display.hasBrightness ? T("外接 · DDC/CI") : T("不可用"))))
                if display.softwareBrightness < 0.999 {
                    infoRow(T("软件调光"), Fmt.percent(display.softwareBrightness))
                }
                infoRow(T("角色"), display.isMain ? T("主显示器") : T("扩展显示器"))
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.8))
        }
    }

    private func brightnessPresets(_ display: DisplayItem) -> some View {
        HStack(spacing: 5) {
            ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { value in
                let active = abs(display.brightness - value) < 0.02
                Button {
                    service.setBrightness(value, for: display.id, animated: true)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: value == 1.0 ? "sun.max.fill" : "sun.min.fill")
                            .font(.system(size: 7.5, weight: .bold))
                        Text(Fmt.percent(value))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background {
                        Capsule().fill(
                            active
                                ? AnyShapeStyle(AuroraTheme.accentGradient)
                                : AnyShapeStyle(Color.primary.opacity(0.05))
                        )
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 14)
    }

    private var restoreCard: some View {
        GlassCard(padding: 12) {
            VStack(spacing: 10) {
                HStack(spacing: 9) {
                    IconBadge(symbol: "arrow.counterclockwise.circle.fill", color: AuroraTheme.accent, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("启动时恢复亮度"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(T("记住每台显示器上次的亮度"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    AuroraToggle(
                        isOn: Binding(
                            get: { service.restoreOnLaunch },
                            set: { value in
                                service.setRestoreOnLaunch(value)
                                state.showToast(value ? T("已记住当前亮度") : T("已关闭亮度记忆"), symbol: "sun.max.fill")
                            }
                        )
                    )
                }

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                HStack(spacing: 9) {
                    IconBadge(symbol: "sun.max.circle.fill", color: AuroraTheme.warn, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("平滑过渡"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(T("切预设时用 0.2 秒缓动，不闪眼"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    AuroraToggle(isOn: $service.smoothTransition)
                }

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                HStack(spacing: 9) {
                    IconBadge(symbol: "keyboard", color: AuroraTheme.accent, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("亮度快捷键"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(T("不打开面板也能微调亮度"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text("⌃⌥↑ / ⌃⌥↓")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
        }
    }

    private var tipCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(AuroraTheme.accent.opacity(0.85))
            Text(T("内建屏使用系统亮度通道，外接屏通过 DDC/CI 通信。若外接屏无响应，请在显示器菜单中开启 DDC/CI。"))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AuroraTheme.accent.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AuroraTheme.accent.opacity(0.14), lineWidth: 0.7)
        }
    }
}
