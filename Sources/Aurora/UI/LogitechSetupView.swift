//  LogitechSetupView.swift
//  Aurora — 罗技鼠标设置向导（欢迎页同款版式）
//
//  检测到罗技鼠标后自动弹出：确认启用 → 检查权限 → 选一个默认方案。
//  插件是长期启用的，鼠标离线也不会关闭，重新连上后自动套用这里选定的默认方案。
//
//  版式约定：三步共用同一个头部位置（图标徽章 + 标题 + 说明），
//  正文用同一种圆角卡片；窗口高度由内容决定（onIdealHeight 回报给窗口控制器），
//  避免早先固定 600pt 高、内容只占上半屏、下半屏一片空白的观感。

import LogitechPlugin
import SwiftUI

struct LogitechSetupView: View {
    @ObservedObject var state: AppState
    @ObservedObject var service: LogitechDeviceService
    @ObservedObject var permissions: PermissionService

    /// 内容理想高度（正文 + 页脚），窗口按它自适应
    var onIdealHeight: ((CGFloat) -> Void)?

    @State private var step: Int
    @State private var profileName = ""
    @State private var defaultChoice: UUID?
    @State private var bodyHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    // 第 3 步的硬件滑杆：拖拽时只改本地值，松手才写进鼠标
    @State private var dpiIndex: Double = 0
    @State private var threshold: Double = 30
    @State private var torque: Double = 50

    init(state: AppState, initialStep: Int = 0, onIdealHeight: ((CGFloat) -> Void)? = nil) {
        self.state = state
        service = state.logitech
        permissions = state.permissions
        self.onIdealHeight = onIdealHeight
        _step = State(initialValue: min(max(initialStep, 0), 3))
    }

    private var device: LogitechKnownDevice? {
        service.pendingSetup ?? service.knownDevice(for: service.selectedID)
    }

    private var deviceID: String? { service.selectedDevice?.id ?? service.selectedID }

    private var deviceProfiles: [LogitechProfile] {
        guard let deviceID else { return [] }
        return service.profiles.filter { $0.deviceID == deviceID }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 24) {
                header
                stepBody
            }
            .padding(.top, 36)
            .padding(.horizontal, 44)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                bodyHeight = height
                reportHeight()
            }

            Divider().opacity(0.65)

            footer
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    footerHeight = height
                    reportHeight()
                }
        }
        .frame(width: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            state.permissions.recheck()
            defaultChoice = service.selectedDefaultProfileID
        }
    }

    private func reportHeight() {
        guard bodyHeight > 0, footerHeight > 0 else { return }
        onIdealHeight?(bodyHeight + footerHeight)
    }

    // MARK: - 头部（三步共用位置）

    private var header: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(AuroraTheme.accent.opacity(0.13))
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(AuroraTheme.accent.opacity(0.22), lineWidth: 0.8)
                Image(systemName: headerSymbol)
                    .font(.system(size: 27, weight: .regular))
                    .foregroundStyle(AuroraTheme.accent)
            }
            .frame(width: 68, height: 68)
            .accessibilityHidden(true)

            Text(headerTitle)
                .font(.system(size: 25, weight: .bold))
                .padding(.top, 17)

            Text(headerDetail)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(1.5)
                .frame(maxWidth: 432)
                .padding(.top, 7)
        }
        .frame(maxWidth: .infinity)
    }

    private var headerSymbol: String {
        switch step {
        case 0: return "computermouse.fill"
        case 1: return "lock.shield.fill"
        case 2: return "slider.horizontal.3"
        default: return "star.fill"
        }
    }

    private var headerTitle: String {
        switch step {
        case 0: return T("发现罗技鼠标")
        case 1: return T("启用插件并允许访问")
        case 2: return T("调整鼠标")
        default: return T("选择默认方案")
        }
    }

    private var headerDetail: String {
        switch step {
        case 0:
            if let device { return device.name + " · " + transportLabel(device.transport) }
            return T("暂时没有检测到罗技鼠标，可以先把设置准备好。")
        case 1:
            return T("插件保持长期启用；权限只用于读写鼠标硬件与按键事件。")
        case 2:
            return T("改完立刻写进鼠标，下一步可以把这套配置存成方案并设为默认。")
        default:
            return T("每次连接这只鼠标时自动套用；也可以先不设，稍后在鼠标页里指定。")
        }
    }

    // MARK: - 正文

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case 0: introduction
        case 1: enabling
        case 2: tuning
        default: defaultProfile
        }
    }

    // 第 1 步：能力说明

    private var introduction: some View {
        VStack(spacing: 0) {
            benefit("bolt.horizontal.fill", "硬件级调节", "DPI、SmartShift 与滚轮模式直接写入鼠标，不需要安装 Options+。")
            rowDivider
            benefit("hand.tap.fill", "侧键与手势键", "把罗技特殊按键映射成启动台、调度中心或任意应用。")
            rowDivider
            benefit("pin.fill", "长期启用", "鼠标暂时离线也不会关闭插件；重新连接后自动恢复，并套用你选定的默认方案。")
        }
        .wizardCard()
    }

    private func benefit(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AuroraTheme.accent)
                .frame(width: 20, height: 18, alignment: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(T(title)).font(.system(size: 12.5, weight: .semibold))
                Text(T(detail))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1.5)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // 第 2 步：启用与权限

    private var enabling: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(T("启用罗技鼠标插件")).font(.system(size: 12.5, weight: .semibold))
                    Text(T("关闭后不再接管任何罗技按键；鼠标离线时插件依然保留，连接后自动接管。"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1.5)
                }
                Spacer(minLength: 10)
                Toggle("", isOn: Binding(get: { service.isEnabled }, set: { service.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .wizardCard()

            VStack(spacing: 0) {
                ForEach(Array(permissionItems.enumerated()), id: \.element.id) { index, item in
                    PermissionRow(item: item, service: permissions)
                    if index < permissionItems.count - 1 { Divider().padding(.leading, 44) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .wizardCard()

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(T("权限随时可以在「设置 › 权限」里更改；没有授权时插件只会读取设备能力，不会接管按键。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1.5)
                Spacer(minLength: 10)
                HStack(spacing: 6) {
                    if permissions.isChecking { ProgressView().controlSize(.mini) }
                    Button(T("重新检测权限")) { permissions.recheck() }
                        .controlSize(.small)
                        .disabled(permissions.isChecking)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
    }

    private var permissionItems: [PermissionService.Item] {
        permissions.items.filter { $0.id == "accessibility" || $0.id == "input" || $0.id == "notifications" }
    }

    // 第 3 步：调整鼠标

    @ViewBuilder
    private var tuning: some View {
        if let device = service.selectedDevice {
            VStack(spacing: 12) {
                VStack(spacing: 0) {
                    if let dpi = device.dpi, !device.supportedDPI.isEmpty {
                        dpiRow(device, current: dpi)
                    }
                    if device.wheelMode != nil {
                        if device.dpi != nil { rowDivider }
                        wheelRow(device)
                    }
                    if device.supportsTorque, device.torque != nil {
                        rowDivider
                        torqueRow(device)
                    }
                    if let high = device.highResolution {
                        rowDivider
                        highResolutionRow(high)
                    }
                    if device.dpi == nil && device.wheelMode == nil && device.highResolution == nil {
                        Text(T("此设备没有报告可调节的硬件项。"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .padding(15)
                    }
                }
                .wizardCard()

                if !divertibleButtons.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(divertibleButtons.enumerated()), id: \.element.id) { index, button in
                            buttonRow(device, button)
                            if index < divertibleButtons.count - 1 { rowDivider }
                        }
                    }
                    .wizardCard()
                }

                Text(T("这里只放最常用的几项，更多按键与高级项可以在鼠标页继续调整。"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        } else {
            offlineTuning
        }
    }

    private func dpiRow(_ device: LogitechDevice, current: Int) -> some View {
        let stops = device.supportedDPI
        let shown = stops[min(max(Int(dpiIndex.rounded()), 0), stops.count - 1)]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(T("指针速度（DPI）")).font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 8)
                Text("\(shown)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AuroraTheme.accent)
            }
            AuroraSlider(
                value: $dpiIndex,
                range: 0...Double(max(1, stops.count - 1)),
                trackHeight: 5,
                step: 1,
                onCommit: {
                    let target = stops[min(max(Int(dpiIndex.rounded()), 0), stops.count - 1)]
                    if target != device.dpi { service.setDPI(target) }
                }
            )
            .disabled(stops.count < 2 || service.isBusy)
            Text(stops.count < 2 ? T("这台鼠标只有一个固定档位") : TF("%d 档可选，拖到松手才写入鼠标", stops.count))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .onAppear { dpiIndex = Double(stops.firstIndex(of: current) ?? 0) }
        .onChange(of: current) { _, value in dpiIndex = Double(stops.firstIndex(of: value) ?? 0) }
    }

    private func wheelRow(_ device: LogitechDevice) -> some View {
        let choice = LogitechWheelChoice.current(device)
        return VStack(alignment: .leading, spacing: 9) {
            Text(T("滚轮模式")).font(.system(size: 11.5, weight: .medium))
            HStack(spacing: 6) {
                ForEach(LogitechWheelChoice.allCases) { item in
                    wheelButton(title: T(item.title), selected: choice == item) {
                        service.setWheel(item)
                    }
                }
            }
            if choice == .automatic {
                HStack(spacing: 8) {
                    Text(T("阈值"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 54, alignment: .leading)
                    AuroraSlider(value: $threshold, range: 1...50, trackHeight: 4, step: 1, onCommit: {
                        service.setWheel(.automatic, threshold: Int(threshold))
                    })
                    Text("\(Int(threshold))")
                        .font(.system(size: 10, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .disabled(service.isBusy)
        .onAppear { threshold = Double(min(max(device.smartShiftThreshold ?? 30, 1), 50)) }
    }

    private func torqueRow(_ device: LogitechDevice) -> some View {
        HStack(spacing: 8) {
            Text(T("阻尼"))
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 64, alignment: .leading)
            AuroraSlider(value: $torque, range: 1...100, trackHeight: 4, step: 1, onCommit: {
                service.setWheel(LogitechWheelChoice.current(device), torque: Int(torque))
            })
            Text("\(Int(torque))%")
                .font(.system(size: 10, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .disabled(service.isBusy)
        .onAppear { torque = Double(device.torque ?? 50) }
    }

    private func highResolutionRow(_ enabled: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(T("高分辨率滚轮")).font(.system(size: 11.5, weight: .medium))
                Text(T("滚轮每格上报更细的位移")) .font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { enabled }, set: { service.setHighResolution($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .disabled(service.isBusy)
    }

    private func wheelButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(Color.primary.opacity(0.06)))
                }
        }
        .buttonStyle(.plain)
    }

    private var divertibleButtons: [LogitechButton] {
        guard let device = service.selectedDevice else { return [] }
        return Array(device.buttons.filter(\.canDivert).prefix(4))
    }

    private func buttonRow(_ device: LogitechDevice, _ button: LogitechButton) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(T(button.name)).font(.system(size: 11.5))
                Text(statusText(device, button)).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(
                get: { service.bindings[device.id]?[String(button.id)] ?? "none" },
                set: { select($0, button: button.id) }
            )) {
                Text(T("设备默认行为")).tag("none")
                ForEach(MacroAction.allCases.filter { $0 != .none }) { Text(T($0.title)).tag($0.rawValue) }
                Text(T("切换罗技方案")).tag("plugin.cycleProfile")
                Text(T("切换 DPI 档位")).tag("plugin.cycleDPI")
                Text(T("切换滚轮模式")).tag("plugin.toggleWheel")
                if let value = service.bindings[device.id]?[String(button.id)], value.hasPrefix("app:") {
                    Text(URL(fileURLWithPath: String(value.dropFirst(4))).deletingPathExtension().lastPathComponent)
                        .tag(value)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 150)
            .disabled(service.isBusy)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
    }

    private func statusText(_ device: LogitechDevice, _ button: LogitechButton) -> String {
        guard service.isMappingActive(button.id, deviceID: device.id) else { return T("设备默认行为") }
        return T(LogitechButtonPolicy.nativeButton(cid: button.id, transport: device.transport) == nil ? "已接管" : "原生事件映射")
    }

    private func select(_ action: String, button: UInt16) {
        if action == MacroAction.openApplication.rawValue {
            ApplicationPicker.choose { url in
                if let url { service.setBinding(button, action: "app:" + url.path) }
            }
        } else {
            service.setBinding(button, action: action)
        }
    }

    private var offlineTuning: some View {
        VStack(spacing: 9) {
            Image(systemName: "computermouse")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
            Text(T("鼠标暂时不在线，连上后才能直接调 DPI 与滚轮。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(T("可以直接跳到下一步：连上后会自动套用你选的方案。"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .wizardCard()
    }

    // 第 4 步：默认方案

    private var defaultProfile: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                choiceRow(title: T("不设默认方案"), subtitle: T("连接后保持鼠标当前的硬件设置"), value: nil)
                ForEach(deviceProfiles) { profile in
                    rowDivider
                    choiceRow(title: profile.name, subtitle: summary(profile), value: profile.id)
                }
            }
            .wizardCard()

            if deviceProfiles.isEmpty {
                Text(T("还没有保存的方案，先在下面把当前设置存成一个方案。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(T("保存当前配置")).font(.system(size: 12.5, weight: .semibold))
                HStack(spacing: 8) {
                    TextField(T("方案名称"), text: $profileName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { save() }
                    Button(T("保存")) { save() }
                        .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || service.selectedDevice == nil || service.isBusy)
                }
                if service.selectedDevice == nil {
                    Text(T("鼠标不在线，连上后才能保存当前配置。"))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else {
                    Text(T("方案会保存 DPI、滚轮模式与罗技按键映射。"))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                if let message = service.message {
                    Text(T(message)).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .wizardCard()
        }
    }

    private func choiceRow(title: String, subtitle: String, value: UUID?) -> some View {
        let selected = defaultChoice == value
        return Button {
            defaultChoice = value
            service.setDefaultProfile(value, for: deviceID)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: selected ? "inset.filled.circle" : "circle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? AuroraTheme.accent : Color.secondary.opacity(0.55))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.primary)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if selected, value != nil {
                    Text(T("默认"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(AuroraTheme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(AuroraTheme.accent.opacity(0.14)))
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .background(selected ? AuroraTheme.accent.opacity(0.07) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.8)
            .padding(.leading, 16)
    }

    private func summary(_ profile: LogitechProfile) -> String {
        var parts: [String] = []
        if let dpi = profile.dpi { parts.append("\(dpi) DPI") }
        if let mode = profile.wheelMode {
            parts.append(mode == 1 ? T("自由滚动") : T("分段滚动"))
        }
        let mapped = profile.bindings.values.filter { $0 != "none" }.count
        if mapped > 0 { parts.append(TF("%d 个按键映射", mapped)) }
        return parts.isEmpty ? T("仅按键映射") : parts.joined(separator: " · ")
    }

    private func save() {
        service.saveProfile(name: profileName)
        if let latest = deviceProfiles.last {
            defaultChoice = latest.id
            service.setDefaultProfile(latest.id, for: deviceID)
        }
        profileName = ""
    }

    // MARK: - 公共

    private func transportLabel(_ transport: String) -> String {
        let lower = transport.lowercased()
        if lower.contains("bluetooth") { return T("蓝牙") }
        if lower.contains("usb") { return "USB" }
        return transport.isEmpty ? T("其他") : transport
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(T("稍后设置")) { finish() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                ForEach(0..<4) { index in
                    Capsule()
                        .fill(step == index ? AuroraTheme.accent : Color.secondary.opacity(0.25))
                        .frame(width: step == index ? 16 : 6, height: 6)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(T("设置步骤"))
            .accessibilityValue("\(step + 1) / 4")

            Spacer(minLength: 8)

            if step > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { step -= 1 }
                } label: {
                    Text(T("返回"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }
            // 系统 borderedProminent 在这里抢不到主色，干脆自己画一个，明暗两种外观都稳
            Button {
                if step < 3 { withAnimation(.easeInOut(duration: 0.18)) { step += 1 } }
                else { finish() }
            } label: {
                Text(step == 3 ? T("完成") : T("继续"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(AuroraTheme.accentGradient))
                    .shadow(color: AuroraTheme.accent.opacity(0.28), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
    }

    private func finish() {
        service.markSetupDone(device?.identity)
        if service.isEnabled && service.isAvailable && service.devices.isEmpty { service.connect() }
        step = 0
        state.showLogitechSetup = false
    }
}

// MARK: - 卡片外观

private struct WizardCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.8)
            }
    }
}

private extension View {
    func wizardCard() -> some View { modifier(WizardCard()) }
}
