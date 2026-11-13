//  DisplayAdvancedSettings.swift
//  Aurora — 显示器高级设置（对齐 MonitorControl 的 Displays 高级面板）
//
//  每台显示器：自定义名称 / DDC 量程 / 反向 / 曲线 / 强制软件调光 / 是否参与键盘调节 / OSD 开关
//  全局行为：跟随鼠标所在屏、多屏同步、接管原生亮度键、软件调光与介入点

import SwiftUI

struct DisplayAdvancedSettings: View {
    @ObservedObject var service: DisplayService
    @ObservedObject var tunings: DisplayTuningStore
    let display: DisplayItem
    @State private var expanded = false
    @State private var customName = ""
    @State private var maxValue = ""
    @State private var minValue = ""

    private var tuning: DisplayTuning { tunings.tuning(for: display.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(T("高级"))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 9) {
                    nameRow
                    if !display.isBuiltIn {
                        ddcRangeRow
                        curveRow
                        toggleRow(T("反向调光"), T("个别显示器 0 是最亮、100 是最暗"), isOn: Binding(
                            get: { service.tunings.tuning(for: display.id).isInverted(.brightness) },
                            set: { value in service.tunings.update(display.id) { $0.invert["brightness"] = value } }
                        ))
                    }
                    toggleRow(T("强制软件调光"), T("不动硬件背光，只用 gamma 压暗"), isOn: Binding(
                        get: { service.tunings.tuning(for: display.id).softwareOnly },
                        set: { service.setSoftwareOnly($0, for: display.id) }
                    ))
                    toggleRow(T("参与键盘调节"), T("关闭后 F1 / F2 不会调这台显示器"), isOn: Binding(
                        get: { service.tunings.tuning(for: display.id).keyboardEnabled },
                        set: { value in service.tunings.update(display.id) { $0.keyboardEnabled = value } }
                    ))
                    toggleRow(T("调节时显示 OSD"), nil, isOn: Binding(
                        get: { !service.tunings.tuning(for: display.id).hideOSD },
                        set: { value in service.tunings.update(display.id) { $0.hideOSD = !value } }
                    ))
                    if display.hasVolume && !display.isBuiltIn {
                        toggleRow(T("静音联动"), T("音量拖到 0 时同时发送显示器静音指令"), isOn: Binding(
                            get: { service.tunings.tuning(for: display.id).muteAtZero },
                            set: { value in service.tunings.update(display.id) { $0.muteAtZero = value } }
                        ))
                    }
                    HStack {
                        Text(display.ddcMax.map { TF("显示器报告的最大值：%d", $0) } ?? T("未读到 DDC 量程"))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 4)
                        Button(T("恢复此屏默认")) {
                            service.resetTuning(for: display.id)
                            syncFields()
                        }
                        .buttonStyle(SoftButtonStyle())
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear(perform: syncFields)
        .onChange(of: display.id) { _, _ in syncFields() }
        .onChange(of: display.name) { _, _ in syncFields() }
    }

    private var nameRow: some View {
        HStack(spacing: 6) {
            Text(T("名称"))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            TextField(display.nativeName, text: $customName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 9.5))
                .onSubmit { service.rename(customName, for: display.id) }
            Button(T("应用")) { service.rename(customName, for: display.id) }
                .controlSize(.small)
                .disabled(customName == tuning.customName)
        }
    }

    private var ddcRangeRow: some View {
        HStack(spacing: 6) {
            Text(T("DDC 量程"))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            TextField(display.ddcMax.map(String.init) ?? "100", text: $maxValue)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 9.5, design: .rounded))
                .frame(width: 52)
                .onSubmit { commitRange() }
            Text("–")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            TextField("0", text: $minValue)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 9.5, design: .rounded))
                .frame(width: 44)
                .onSubmit { commitRange() }
            Button(T("应用")) { commitRange() }
                .controlSize(.small)
            Spacer(minLength: 0)
        }
    }

    private var curveRow: some View {
        HStack(spacing: 6) {
            Text(T("亮度曲线"))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Picker("", selection: Binding(
                get: { service.tunings.tuning(for: display.id).curveValue(.brightness) },
                set: { value in service.tunings.update(display.id) { $0.curve["brightness"] = value } }
            )) {
                Text(T("线性")).tag(1.0)
                Text(T("低亮度更细腻")).tag(0.7)
                Text(T("低亮度更陡")).tag(1.4)
            }
            .labelsHidden()
            .controlSize(.small)
            Spacer(minLength: 0)
        }
    }

    private func toggleRow(_ title: String, _ subtitle: String?, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 9.5))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            AuroraToggle(isOn: isOn)
        }
    }

    private func syncFields() {
        customName = tuning.customName
        maxValue = tuning.max(.brightness) > 0 ? String(tuning.max(.brightness)) : (display.ddcMax.map(String.init) ?? "")
        minValue = tuning.min(.brightness) > 0 ? String(tuning.min(.brightness)) : ""
    }

    private func commitRange() {
        let maxParsed = Int(maxValue.trimmingCharacters(in: .whitespaces))
        let minParsed = Int(minValue.trimmingCharacters(in: .whitespaces)) ?? 0
        service.tunings.update(display.id) {
            $0.maxValue["brightness"] = maxParsed ?? 0
            $0.minValue["brightness"] = min(minParsed, (maxParsed ?? 255) - 1)
        }
        if let current = service.displays.first(where: { $0.id == display.id })?.brightness {
            service.setBrightness(current, for: display.id)
        }
    }
}

/// 全局行为：跟随鼠标 / 多屏同步 / 原生亮度键 / OSD / 软件调光
struct DisplayBehaviorCard: View {
    @ObservedObject var service: DisplayService
    @ObservedObject var permissions: PermissionService

    var body: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: T("调节行为"), symbol: "display.2")

                row(
                    symbol: "cursorarrow.motionlines",
                    title: T("跟随鼠标所在显示器"),
                    subtitle: T("键盘调亮度时作用于指针所在的屏"),
                    isOn: $service.followMouse
                )
                linkRow

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                row(
                    symbol: "sun.max",
                    title: T("接管键盘亮度键"),
                    subtitle: nativeKeySubtitle,
                    isOn: Binding(
                        get: { service.useNativeKeys },
                        set: { service.useNativeKeys = $0 }
                    )
                )
                row(
                    symbol: "rectangle.bottomthird.inset.filled",
                    title: T("调节时显示 OSD"),
                    subtitle: T("屏幕底部显示 16 格方块"),
                    isOn: $service.showOSD
                )

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                row(
                    symbol: "circle.lefthalf.filled",
                    title: T("软件调光"),
                    subtitle: T("硬件到底后继续压 gamma，可暗到接近全黑"),
                    isOn: $service.combinedDimming
                )
                if service.combinedDimming {
                    HStack(spacing: 8) {
                        Text(T("介入点"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                        AuroraSlider(
                            value: Binding(
                                get: { service.switchingPoint },
                                set: { service.switchingPoint = $0 }
                            ),
                            range: 0.05...0.7,
                            tickStep: 0.1,
                            step: 0.01
                        )
                        Text(Fmt.percent(service.switchingPoint))
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                    .padding(.leading, 2)
                    Text(T("低于介入点后硬件保持最暗，再由 gamma 继续压暗；数值越大软件调光参与得越早。"))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var nativeKeySubtitle: String {
        if !service.useNativeKeys { return T("F1 / F2 交给系统处理") }
        if service.nativeKeysActive { return T("F1 / F2 直接调外接屏，按住 ⌥⇧ 细调") }
        return permissions.accessibility ? T("正在等待键盘事件接入") : T("需要辅助功能权限")
    }

    /// 多屏亮度联动：比原来的「同步」开关多三种方式
    private var linkRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(service.linkMode == .off ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(AuroraTheme.accent))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(T("亮度联动")).font(.system(size: 11, weight: .medium))
                Text(service.linkMode.detail)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Picker("", selection: $service.linkMode) {
                ForEach(BrightnessLink.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 118)
        }
    }

    private func row(symbol: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            AuroraToggle(isOn: isOn)
        }
    }
}
