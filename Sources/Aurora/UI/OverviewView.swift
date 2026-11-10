//  OverviewView.swift
//  Aurora — 资源概览

import SwiftUI

enum ProcessMetric: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return T("内存")
        case .network: return T("网络")
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "cpu.fill"
        case .memory: return "memorychip"
        case .network: return "network"
        }
    }
}

struct OverviewView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var state: AppState
    @ObservedObject private var traffic: NetworkProcessSampler
    @ObservedObject private var speed: SpeedTester
    @ObservedObject private var deviceStore: DeviceService
    @State private var metric: ProcessMetric = .cpu

    init(state: AppState) {
        self.state = state
        self.monitor = state.monitor
        self.traffic = state.networkProcesses
        self.speed = state.speedTest
        self.deviceStore = state.devices
    }

    var body: some View {
        AdaptiveCardGrid(
            cards: [
                AnyView(cpuCard),
                AnyView(gpuCard),
                AnyView(memoryCard),
                AnyView(networkCard),
                AnyView(diskCard),
                AnyView(batteryCard)
            ],
            wide: [AnyView(devicesCard), AnyView(processCard)]
        )
    }

    // MARK: - CPU

    private var cpuCard: some View {
        GlassCard {
            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    RingGauge(
                        value: monitor.cpu,
                        size: 76,
                        lineWidth: 7,
                        centerText: Fmt.percent(monitor.cpu),
                        caption: "CPU"
                    )

                    VStack(alignment: .leading, spacing: 7) {
                        Text(T("处理器"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.7)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 4) {
                            Text(TF("%d 核", ProcessInfo.processInfo.processorCount))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                            Text("·").foregroundStyle(.tertiary)
                            Text(systemLoadLabel)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Text(TF("已运行 %@", Fmt.uptime(monitor.uptime)))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(Array(monitor.perCore.prefix(14).enumerated()), id: \.offset) { _, value in
                                RoundedRectangle(cornerRadius: 1.8, style: .continuous)
                                    .fill(coreColor(value))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: max(4, 22 * value))
                                    .frame(height: 22, alignment: .bottom)
                            }
                        }
                        .frame(height: 22, alignment: .bottom)
                    }
                }

                Sparkline(values: monitor.cpuHistory, color: AuroraTheme.accent, maxValue: 1)
                    .frame(height: 30)
            }
        }
    }

    private var systemLoadLabel: String {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return String(format: T("负载 %.2f"), load[0])
    }

    private func coreColor(_ value: Double) -> Color {
        if value > 0.85 { return AuroraTheme.danger }
        if value > 0.55 { return AuroraTheme.warn }
        return AuroraTheme.accent.opacity(0.85)
    }

    private var gpuCard: some View {
        GlassCard {
            VStack(spacing: 10) {
                HStack(spacing: 14) {
                    RingGauge(
                        value: monitor.gpu.utilization,
                        size: 66,
                        lineWidth: 6,
                        centerText: Fmt.percent(monitor.gpu.utilization),
                        caption: "GPU"
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(T("显卡"))
                                .font(.system(size: 9.5, weight: .semibold))
                                .tracking(0.7)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            if monitor.gpu.cores > 0 {
                                Text("\(monitor.gpu.cores) \(T("核"))")
                                    .font(.system(size: 9, design: .rounded))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Text(monitor.gpu.available ? monitor.gpu.name : T("不可用"))
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)

                        HStack(spacing: 12) {
                            labeled(T("显存"), Fmt.bytes(monitor.gpu.memoryUsed))
                            labeled(T("神经网络引擎"), monitor.neuralEngineAvailable ? T("可用") : T("不可用"))
                        }
                    }
                }

                Sparkline(values: monitor.gpuHistory, color: AuroraTheme.accent, maxValue: 1)
                    .frame(height: 24)
                    .opacity(monitor.gpu.available ? 1 : 0.25)
            }
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.75))
                .monospacedDigit()
        }
    }

    // MARK: - 内存

    private var memoryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: T("内存"), symbol: "memorychip")
                    Spacer()
                    Text("\(Fmt.bytes(monitor.memory.used)) / \(Fmt.bytes(monitor.memory.total))")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                MeterBar(
                    value: monitor.memory.usage,
                    height: 8,
                    gradient: LinearGradient(
                        colors: [AuroraTheme.accent, AuroraTheme.accent],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

                HStack(spacing: 14) {
                    legend(color: AuroraTheme.accent, title: T("应用"), value: monitor.memory.app)
                    legend(color: AuroraTheme.accent, title: T("联动"), value: monitor.memory.wired)
                    legend(color: AuroraTheme.warn, title: T("压缩"), value: monitor.memory.compressed)
                }
            }
        }
    }

    private func legend(color: Color, title: String, value: UInt64) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(.system(size: 9.5)).foregroundStyle(.secondary)
            Text(Fmt.bytes(value))
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.75))
                .monospacedDigit()
        }
    }

    // MARK: - 网络

    private var networkCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("网络"), symbol: "network")

                    if let vpn = vpnStatus.summary {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 7.5, weight: .bold))
                            Text(vpn)
                                .font(.system(size: 8.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(AuroraTheme.ok)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(AuroraTheme.ok.opacity(0.12)))
                    }

                    Spacer(minLength: 0)

                    Button {
                        speed.run()
                    } label: {
                        HStack(spacing: 3.5) {
                            if speed.isRunning {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.65)
                                    .frame(width: 9, height: 9)
                            } else {
                                Image(systemName: "speedometer")
                                    .font(.system(size: 8.5, weight: .bold))
                            }
                            Text(speed.isRunning ? T("测速中…") : T("测速"))
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .disabled(speed.isRunning)
                }

                HStack(spacing: 12) {
                    HStack(spacing: 10) {
                        rateLabel(symbol: "arrow.down", value: monitor.network.download, color: AuroraTheme.ok)
                        rateLabel(symbol: "arrow.up", value: monitor.network.upload, color: AuroraTheme.warn)
                    }
                    Spacer(minLength: 0)
                    Sparkline(values: monitor.netHistory.map(\.down), color: AuroraTheme.ok, maxValue: nil)
                        .frame(width: 120, height: 30)
                }

                if let down = speed.downloadMbps, let up = speed.uploadMbps {
                    HStack(spacing: 10) {
                        Text(TF("下行 %.1f Mbps", down))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text(TF("上行 %.1f Mbps", up))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                } else if let error = speed.error {
                    Text(error)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var vpnStatus: VPNStatus { VPNProbe.current() }

    private func rateLabel(symbol: String, value: Double, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(color)
            Text(Fmt.rate(value))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.85))
        }
    }

    // MARK: - 磁盘 / 电池

    private var diskCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(AuroraTheme.accent)
                    Text(T("磁盘"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                // 主数字给「剩余」——这才是每天真正关心的量；已用放到副标题
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.bytes(monitor.disk.free))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(T("剩余"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(TF("已用 %@", Fmt.bytes(monitor.disk.total - monitor.disk.free)))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("·").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(TF("共 %@", Fmt.bytes(monitor.disk.total)))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                // 实时读写：IOBlockStorageDriver 累计值差分，用来判断是谁在拖慢机器
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(AuroraTheme.accent)
                    Text(Fmt.rate(monitor.disk.readRate))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(AuroraTheme.ok)
                        .padding(.leading, 2)
                    Text(Fmt.rate(monitor.disk.writeRate))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                MeterBar(value: monitor.disk.usage, height: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var batteryCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: batterySymbol)
                        .font(.system(size: 9))
                        .foregroundStyle(monitor.battery.map { $0.level > 0.2 ? AuroraTheme.ok : AuroraTheme.danger } ?? .secondary)
                    Text(T("电池"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Text(monitor.battery.map { Fmt.percent($0.level) } ?? "—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(batteryCaption)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                HStack(spacing: 4) {
                    if let health = monitor.battery?.health {
                        Text(TF("健康 %@", Fmt.percent(health)))
                            .font(.system(size: 9))
                            .foregroundStyle(health < 0.8 ? AuroraTheme.warn : .secondary)
                    }
                    if let cycles = monitor.battery?.cycleCount {
                        if monitor.battery?.health != nil {
                            Text("·").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                        Text(TF("循环 %d 次", cycles))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                MeterBar(
                    value: monitor.battery?.level ?? 0,
                    height: 4,
                    gradient: LinearGradient(
                        colors: [AuroraTheme.ok, AuroraTheme.accent],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var batterySymbol: String {
        guard let battery = monitor.battery else { return "battery.0percent" }
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.level {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var batteryCaption: String {
        guard let battery = monitor.battery else { return T("无电池") }
        if battery.isCharging { return TF("充电中 · %@ 充满", Fmt.minutes(battery.minutesRemaining)) }
        if battery.isPluggedIn { return T("已接通电源") }
        return TF("剩余 %@", Fmt.minutes(battery.minutesRemaining))
    }

    // MARK: - 外部设备

    private var devicesCard: some View {
        let list = deviceStore.devices
        return GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("外部设备"), symbol: "cable.connector")
                    if !list.isEmpty {
                        Text("\(list.count)")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    Spacer(minLength: 0)
                    Text(TF("已连接 %d", list.filter(\.online).count))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }

                if list.isEmpty {
                    Text(T("没有检测到外接设备"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 6) {
                        ForEach(list.prefix(6)) { device in
                            deviceRow(device)
                        }
                    }
                    if list.count > 6 {
                        Text(TF("还有 %d 个设备", list.count - 6))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func deviceRow(_ device: ExternalDevice) -> some View {
        HStack(spacing: 8) {
            IconBadge(
                symbol: device.symbol,
                color: device.isApple ? AuroraTheme.accent : Color.secondary,
                size: 22,
                style: .tinted
            )

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(device.name)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                    if device.isApple {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(subtitle(device))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let total = device.storageTotal, total > 0 {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(Fmt.bytes(total - (device.storageUsed ?? 0)))
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary.opacity(0.8))
                    MeterBar(
                        value: Double(device.storageUsed ?? 0) / Double(total),
                        height: 2.5
                    )
                    .frame(width: 54)
                }
            } else if let battery = device.battery {
                HStack(spacing: 3) {
                    Image(systemName: batterySymbol(battery, charging: device.charging))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(battery > 20 ? AuroraTheme.ok : AuroraTheme.danger)
                    Text("\(battery)%")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary.opacity(0.8))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
            } else if !device.batteryParts.isEmpty {
                Text("\(device.batteryParts.first?.level ?? 0)%")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            } else {
                Text(device.connection)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func subtitle(_ device: ExternalDevice) -> String {
        var parts: [String] = device.online ? [device.connection] : []
        if let model = device.model, !model.isEmpty, model != device.name {
            parts.append(model)
        } else {
            parts.append(device.kindLabel)
        }
        if !device.batteryParts.isEmpty {
            let text = device.batteryParts
                .map { "\($0.label) \($0.level)%" }
                .joined(separator: " · ")
            parts.append(text)
        } else if let detail = device.detail {
            parts.append(detail)
        }
        return parts.joined(separator: " · ")
    }

    private func batterySymbol(_ level: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    // MARK: - 占用最高

    private var processCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    SectionLabel(text: T("占用最高"), symbol: "list.bullet")
                    Spacer(minLength: 4)
                    metricPicker
                }

                switch metric {
                case .cpu:
                    let ranked = monitor.processes.prefix(6)
                    let peak = max(ranked.first?.cpu ?? 1, 1)
                    processList(ranked.map {
                        RowModel(pid: $0.id, name: $0.name, value: String(format: "%.0f%%", $0.cpu),
                                 detail: Fmt.bytes($0.memory), ratio: min($0.cpu / peak, 1))
                    })
                case .memory:
                    let ranked = monitor.processes.sorted { $0.memory > $1.memory }.prefix(6)
                    let peak = Double(ranked.first?.memory ?? 1)
                    processList(ranked.map {
                        RowModel(pid: $0.id, name: $0.name, value: Fmt.bytes($0.memory),
                                 detail: String(format: "%.0f%% CPU", $0.cpu),
                                 ratio: peak > 0 ? Double($0.memory) / peak : 0)
                    })
                case .gpu:
                    gpuDetail
                case .network:
                    networkDetail
                }

                if metric == .cpu || metric == .memory {
                    Text(T("按 CPU 时间与常驻内存采样，可切换指标"))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { traffic.setEnabled(metric == .network) }
        .onDisappear { traffic.setEnabled(false) }
        .onChange(of: metric) { _, value in
            traffic.setEnabled(value == .network)
        }
    }

    private var metricPicker: some View {
        HStack(spacing: 1) {
            ForEach(ProcessMetric.allCases) { item in
                let active = metric == item
                Button {
                    withAnimation(.smooth(duration: 0.2)) { metric = item }
                } label: {
                    Text(item.title)
                        .font(.system(size: 8.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3.5)
                        .background {
                            if active {
                                Capsule().fill(AuroraTheme.accentGradient)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(1.5)
        .background(Capsule().fill(Color.primary.opacity(0.055)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6))
    }

    private struct RowModel: Identifiable {
        let pid: pid_t
        let name: String
        let value: String
        let detail: String
        let ratio: Double
        var id: pid_t { pid }
    }

    @ViewBuilder
    private func processList(_ rows: [RowModel]) -> some View {
        if rows.isEmpty {
            Text(T("正在采样…"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 5) {
                ForEach(rows) { row in
                    processRow(row)
                }
            }
        }
    }

    private func processRow(_ row: RowModel) -> some View {
        HStack(spacing: 7) {
            processIcon(row.pid)

            VStack(spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(row.detail)
                        .font(.system(size: 8.5, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    Text(row.value)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.78))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                MeterBar(
                    value: min(row.ratio, 1),
                    height: 2.5,
                    gradient: LinearGradient(colors: [AuroraTheme.accent.opacity(0.65), AuroraTheme.accent.opacity(0.65)],
                                             startPoint: .leading, endPoint: .trailing)
                )
            }
        }
    }

    @ViewBuilder
    private func processIcon(_ pid: pid_t) -> some View {
        if let icon = ProcessIcons.shared.icon(for: pid) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 15, height: 15)
        } else {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .frame(width: 15, height: 15)
                .overlay {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private var gpuDetail: some View {
        VStack(alignment: .leading, spacing: 7) {
            statRow(T("利用率"), Fmt.percent(monitor.gpu.utilization), AuroraTheme.accent)
            statRow(T("显存占用"), "\(Fmt.bytes(monitor.gpu.memoryUsed)) / \(Fmt.bytes(max(monitor.gpu.memoryTotal, monitor.gpu.memoryUsed)))", AuroraTheme.accent)
            statRow(T("核心数"), monitor.gpu.cores > 0 ? "\(monitor.gpu.cores)" : "—", .secondary)
            statRow(T("神经网络引擎"), monitor.neuralEngineAvailable ? T("可用") : T("不可用"), monitor.neuralEngineAvailable ? AuroraTheme.ok : .secondary)

            MeterBar(value: monitor.gpu.utilization, height: 4)

            Text(T("macOS 未开放按进程的 GPU 占用，这里展示整卡数据"))
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var networkDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            let items = traffic.items.prefix(5)
            if items.isEmpty {
                Text(T("正在采样…"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(items)) { item in
                    HStack(spacing: 7) {
                        processIcon(item.id)
                        Text(item.name)
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.down").font(.system(size: 7, weight: .bold)).foregroundStyle(AuroraTheme.ok)
                            Text(Fmt.rate(item.download))
                                .font(.system(size: 9, design: .rounded))
                                .monospacedDigit()
                        }
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up").font(.system(size: 7, weight: .bold)).foregroundStyle(AuroraTheme.warn)
                            Text(Fmt.rate(item.upload))
                                .font(.system(size: 9, design: .rounded))
                                .monospacedDigit()
                        }
                        .frame(width: 74, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func statRow(_ title: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint.opacity(tint == .secondary ? 0.35 : 0.8)).frame(width: 4, height: 4)
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.78))
                .monospacedDigit()
        }
    }
}
