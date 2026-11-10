//  PointerView.swift
//  Aurora — 鼠标 / 触控板调校

import SwiftUI

struct PointerView: View {
    @ObservedObject var service: PointerService
    @ObservedObject var permissions: PermissionService
    @ObservedObject var devices: HIDDeviceService
    @ObservedObject var state: AppState
    @StateObject private var probe = PointerProbe()

    init(state: AppState) {
        self.state = state
        self.service = state.pointer
        self.permissions = state.permissions
        self.devices = state.hid
    }

    var body: some View {
        VStack(spacing: 12) {
            if !permissions.accessibility {
                permissionCard
            }

            deviceCard
            LogitechSettingsCard(service: state.logitech)
            pointerCard
            scrollCard
            macroCard
            statusCard
            footer
        }
        .onAppear { probe.start() }
        .onDisappear { probe.stop() }
        .onChange(of: permissions.accessibility) { _, granted in
            // 授权后立即重建事件引擎，不用改滑块才生效
            if granted { service.sync() }
        }
    }

    // MARK: - 已连接的指针设备

    private var deviceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("已连接的指针设备"), symbol: "computermouse.fill")
                    Spacer()
                    Text(TF("%d 个外接", devices.pointers.count))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                    Button {
                        devices.refresh()
                        state.showToast(T("已重新扫描设备"), symbol: "arrow.clockwise")
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .padding(4)
                            .background(Circle().fill(Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }

                if devices.pointers.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "computermouse")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(T("未检测到外接鼠标，只会使用内建触控板"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(spacing: 5) {
                        ForEach(devices.pointers) { device in
                            HStack(spacing: 9) {
                                IconBadge(symbol: device.transportSymbol, size: 26, style: .tinted)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 5) {
                                        Text(device.name)
                                            .font(.system(size: 11, weight: .medium))
                                            .lineLimit(1)
                                        if let battery = device.battery {
                                            Text("\(battery)%")
                                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                                .foregroundStyle(battery <= 20 ? AnyShapeStyle(AuroraTheme.warn) : AnyShapeStyle(.secondary))
                                        }
                                    }
                                    Text("\(device.transportLabel) · \(device.vendorLabel)")
                                        .font(.system(size: 8.5))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 4)
                                Text(T("多设备共用一套参数"))
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary.opacity(0.8))
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 7)
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.035))
                            }
                        }
                    }
                }

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(T("指针测试"))
                            .font(.system(size: 9.5, weight: .medium))
                        Spacer()
                        Text(T("在面板内移动或滚动即可"))
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 5) {
                        probeTile(T("横向"), value: deltaText(probe.dx), symbol: "arrow.left.and.right")
                        probeTile(T("纵向"), value: deltaText(probe.dy), symbol: "arrow.up.and.down")
                        probeTile(T("滚动"), value: deltaText(probe.scrollY), symbol: "scroll")
                        probeTile(T("按键"), value: probe.lastButton.isEmpty ? "—" : probe.lastButton, symbol: "computermouse.fill")
                    }
                }
            }
        }
    }

    private func deltaText(_ value: Double) -> String {
        abs(value) < 0.5 ? "0" : String(format: "%+.0f", value)
    }

    private func probeTile(_ title: String, value: String, symbol: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(probe.active ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(Color.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 7.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    private var permissionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    IconBadge(symbol: "lock.shield.fill", color: AuroraTheme.warn, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("需要辅助功能权限"))
                            .font(.system(size: 12, weight: .semibold))
                        Text(T("调整指针需要接管系统鼠标事件"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button(T("前往授权")) { service.requestPermission() }
                        .buttonStyle(SoftButtonStyle(prominent: true))
                    Button(T("打开系统设置")) { service.openAccessibilitySettings() }
                        .buttonStyle(SoftButtonStyle())
                }
            }
        }
    }

    private var presetRow: some View {
        HStack(spacing: 5) {
            ForEach(presets, id: \.value) { preset in
                let active = abs(service.speed - preset.value) < 0.05
                Button {
                    service.speed = preset.value
                } label: {
                    Text(preset.title)
                        .font(.system(size: 9, weight: .medium))
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

    private var presets: [(title: String, value: Double)] {
        [(T("精细"), 0.7), (T("标准"), 1.0), (T("轻快"), 1.6), (T("极速"), 2.4)]
    }

    private var macroCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("按键映射"), symbol: "computermouse.fill")
                    Spacer(minLength: 0)
                    if service.isCapturing {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(AuroraTheme.accent)
                                .frame(width: 4, height: 4)
                            Text(T("等待按键"))
                                .font(.system(size: 8.5, weight: .medium))
                        }
                        .foregroundStyle(AuroraTheme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(AuroraTheme.accent.opacity(0.12)))
                    } else if let button = service.lastPressedButton {
                        HStack(spacing: 3) {
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 7.5, weight: .bold))
                            Text(TF("最近按下 按键 %d", button))
                                .font(.system(size: 8.5, weight: .medium))
                                .monospacedDigit()
                        }
                        .foregroundStyle(AuroraTheme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(AuroraTheme.accent.opacity(0.12)))
                    }

                    Button {
                        if service.isCapturing {
                            state.endButtonCapture()
                        } else {
                            state.beginButtonCapture()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: service.isCapturing ? "xmark" : "plus")
                                .font(.system(size: 7.5, weight: .bold))
                            Text(service.isCapturing ? T("取消") : T("捕获"))
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(service.isCapturing ? AnyShapeStyle(AuroraTheme.danger) : AnyShapeStyle(AuroraTheme.accent))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                (service.isCapturing ? AuroraTheme.danger : AuroraTheme.accent).opacity(0.12)
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .help(T("先单独捕获一个鼠标按键，再为它指定动作"))
                }

                Text(T("点「捕获」后按下鼠标上的按键即可识别编号；映射后这个键不会再传给前台 App。"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 4) {
                    ForEach(service.mappedButtons, id: \.self) { button in
                        macroRow(button)
                    }
                    if service.isCapturing {
                        capturingRow
                    }
                }
            }
        }
    }

    private func macroRow(_ button: Int) -> some View {
        let highlighted = service.lastPressedButton == button
        return HStack(spacing: 7) {
            HStack(spacing: 5) {
                Text(buttonTitle(button))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(highlighted ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(Color.primary))
                Text(TF("按键 %d", button))
                    .font(.system(size: 8.5, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Spacer(minLength: 6)

            Picker("", selection: Binding(
                get: { service.macroBindings[button] ?? .none },
                set: { service.setMacro($0, for: button) }
            )) {
                ForEach(MacroAction.allCases) { action in
                    Text(T(action.title)).tag(action)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            if service.canForget(button) {
                Button {
                    service.forget(button)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(T("移除这个按键"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(highlighted ? AuroraTheme.accent.opacity(0.10) : Color.clear)
        }
    }

    private var capturingRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "computermouse.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AuroraTheme.accent)
            Text(T("正在等待按键…"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AuroraTheme.accent)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AuroraTheme.accent.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            AuroraTheme.accent.opacity(0.30),
                            style: StrokeStyle(lineWidth: 0.8, dash: [3, 3])
                        )
                }
        }
        .transition(.opacity)
    }

    private func buttonTitle(_ button: Int) -> String {
        switch button {
        case 3: return T("侧键 1")
        case 4: return T("侧键 2")
        default: return T("附加按键")
        }
    }

    private var engineStatusText: String {
        if service.engineReady { return T("实时转换中") }
        if !permissions.accessibility { return T("未授权，无法接管") }
        return service.isDefault ? T("参数为默认，未接管") : T("启动失败，请重试")
    }

    private var statusCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: T("运行状态"), symbol: "waveform.path.ecg")
                statusRow(title: T("辅助功能权限"), value: permissions.accessibility ? T("已授权") : T("未授权"), ok: permissions.accessibility)
                statusRow(
                    title: T("事件接管"),
                    value: engineStatusText,
                    ok: service.engineReady
                )
                statusRow(title: T("作用范围"), value: T("指针位移 · 滚轮"), ok: true)
            }
        }
    }

    private func statusRow(title: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? AuroraTheme.ok : Color.secondary.opacity(0.4))
                .frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ok ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.7))
        }
    }

    private var pointerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(text: T("指针"), symbol: "computermouse")
                    Spacer()
                    Text(service.engineReady ? T("引擎运行中") : T("引擎待命"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(service.engineReady ? AuroraTheme.ok : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                (service.engineReady ? AuroraTheme.ok : Color.primary).opacity(0.10)
                            )
                        )
                }

                SliderRow(
                    symbol: "speedometer",
                    title: T("速度"),
                    value: $service.speed,
                    range: 0.3...3.0,
                    displayText: String(format: "%.1f×", service.speed)
                )

                presetRow

                SliderRow(
                    symbol: "hare.fill",
                    title: T("加速"),
                    value: $service.acceleration,
                    range: 0...1,
                    displayText: Fmt.percent(service.acceleration),
                    tint: LinearGradient(
                        colors: [AuroraTheme.warn, AuroraTheme.danger],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

                Text(T("速度线性缩放位移；加速让快速滑动时指针移动得更远。"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var scrollCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("滚轮"), symbol: "scroll")
                    Spacer(minLength: 0)
                    Button(T("Mos 手感")) {
                        service.smoothScroll = true
                        service.smoothDuration = 0.24
                        service.scrollSpeed = 1.0
                        service.scrollAcceleration = 0.0
                        state.showToast(T("已套用 Mos 平滑预设"), symbol: "wind")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(AuroraTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(AuroraTheme.accent.opacity(0.12)))
                }

                SliderRow(
                    symbol: "scroll.fill",
                    title: T("速度"),
                    value: $service.scrollSpeed,
                    range: 0.3...3.0,
                    displayText: String(format: "%.1f×", service.scrollSpeed),
                    tint: LinearGradient(
                        colors: [AuroraTheme.accent, AuroraTheme.accent],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

                SliderRow(
                    symbol: "hare.fill",
                    title: T("滚动加速度"),
                    value: $service.scrollAcceleration,
                    range: 0...1,
                    displayText: Fmt.percent(service.scrollAcceleration),
                    tint: LinearGradient(
                        colors: [AuroraTheme.warn, AuroraTheme.danger],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

                toggleRow(
                    symbol: "wind",
                    title: T("平滑滚动"),
                    subtitle: service.smoothScroll ? T("滚轮格数插值成连续滚动，接近 Mos 手感") : T("保持系统一格一格的滚动"),
                    isOn: $service.smoothScroll
                )

                if service.smoothScroll {
                    SliderRow(
                        symbol: "timer",
                        title: T("平滑时长"),
                        value: $service.smoothDuration,
                        range: 0.08...0.6,
                        displayText: String(format: "%.2f s", service.smoothDuration)
                    )
                    toggleRow(
                        symbol: "option",
                        title: T("按住 ⌃⌥ 暂停平滑"),
                        subtitle: T("需要精确定位时临时恢复逐格滚动"),
                        isOn: $service.smoothBypass
                    )
                }

                toggleRow(
                    symbol: "computermouse",
                    title: T("反转鼠标滚轮"),
                    subtitle: T("只影响滚轮鼠标，触控板保持原方向"),
                    isOn: $service.invertMouse
                )

                toggleRow(
                    symbol: "hand.draw",
                    title: T("反转触控板"),
                    subtitle: T("只影响触控板与妙控鼠标"),
                    isOn: $service.invertTrackpad
                )

                toggleRow(
                    symbol: "arrow.left.and.right",
                    title: T("Shift 横向滚动"),
                    subtitle: T("按住 Shift 把纵向滚轮变成左右滚动"),
                    isOn: $service.shiftToHorizontal
                )

                HStack(spacing: 10) {
                    Image(systemName: "option")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("按住修饰键临时反转"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(T("松手即恢复，适合触控板与滚轮混用"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Picker("", selection: $service.modifierInvert) {
                        ForEach(ScrollInvertModifier.allCases) { modifier in
                            Text(modifier.title).tag(modifier)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    private func toggleRow(
        symbol: String,
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            AuroraToggle(isOn: isOn)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(T("设置即时生效，不影响系统原有偏好"))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(T("恢复默认")) {
                service.reset()
                state.showToast(T("指针参数已恢复默认"), symbol: "arrow.counterclockwise")
            }
            .buttonStyle(SoftButtonStyle())
            .disabled(service.isDefault)
            .opacity(service.isDefault ? 0.4 : 1)
        }
        .padding(.horizontal, 4)
    }
}
