//  EnergyView.swift
//  Aurora — 休眠管理

import SwiftUI

struct EnergyView: View {
    @ObservedObject var service: EnergyService
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var state: AppState

    init(state: AppState) {
        self.state = state
        self.service = state.energy
        self.monitor = state.monitor
    }

    var body: some View {
        VStack(spacing: 12) {
            heroCard
            durationCard
            infoCard
        }
    }

    private var heroCard: some View {
        GlassCard(padding: 16) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(service.isActive ? AuroraTheme.accent.opacity(0.16) : Color.primary.opacity(0.06))
                            .frame(width: 54, height: 54)
                        Image(systemName: service.isActive ? "cup.and.saucer.fill" : "moon.zzz")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(service.isActive ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(Color.secondary))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(service.isActive ? T("已阻止系统休眠") : T("系统当前可正常休眠"))
                            .font(.system(size: 13, weight: .semibold))
                        if service.isActive {
                            Text(service.endsAt == nil ? T("永不") : "\(T("剩余时间")) \(service.remainingText)")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(AuroraTheme.accent)
                                .monospacedDigit()
                        } else {
                            Text(T("到期后自动恢复系统休眠"))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 4)

                    AuroraToggle(isOn: Binding(
                        get: { service.isActive },
                        set: { active in service.set(active ? .forever : .off) }
                    ))
                }

                HStack(spacing: 8) {
                    Image(systemName: monitor.battery?.isPluggedIn == true ? "powerplug.fill" : "battery.75percent")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(powerDescription)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(T("唤醒期间耗电会增加，建议插电使用"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var powerDescription: String {
        guard let battery = monitor.battery else { return T("无电池") }
        let level = Fmt.percent(battery.level)
        if battery.isPluggedIn {
            return "\(level) · \(T("已接通电源"))"
        }
        return "\(level) · \(T("剩余")) \(Fmt.minutes(battery.minutesRemaining))"
    }

    private var durationCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: T("保持唤醒"), symbol: "timer")

                HStack(spacing: 5) {
                    ForEach(EnergyService.Duration.allCases.filter { $0 != .off }) { option in
                        let active = service.duration == option
                        Button {
                            service.set(option)
                            state.showToast(
                                option == .forever ? TF("保持唤醒 %@", T("永不")) : TF("保持唤醒 %@", option.title),
                                symbol: "cup.and.saucer.fill"
                            )
                        } label: {
                            Text(option == .forever ? T("永不") : localized(option))
                                .font(.system(size: 9.5, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
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

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                HStack(spacing: 9) {
                    Image(systemName: "sun.max")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("同时保持屏幕常亮"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(service.keepDisplayOn ? T("已阻止系统休眠") : T("屏幕可正常休眠"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    AuroraToggle(isOn: $service.keepDisplayOn)
                }

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                HStack(spacing: 9) {
                    Image(systemName: "battery.25percent")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("低电量自动结束"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(T("电池供电且低于 20% 时停止，避免把电耗光"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    AuroraToggle(isOn: $service.autoStopOnLowBattery)
                }

                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.6)

                HStack(spacing: 9) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("启动时自动开启"))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(T("登录后直接进入保持唤醒"))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    AuroraToggle(isOn: $service.activateOnLaunch)
                }
            }
        }
    }

    private var infoCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: T("运行状态"), symbol: "waveform.path.ecg")
                row(T("保持唤醒"), service.isActive ? T("已阻止系统休眠") : T("关闭"), ok: service.isActive)
                row(T("屏幕"), service.keepDisplayOn ? T("常亮") : T("跟随系统"), ok: service.keepDisplayOn)
                row(T("低电量保护"), service.autoStopOnLowBattery ? T("20% 自动结束") : T("关闭"), ok: service.autoStopOnLowBattery)
                HStack {
                    Text(T("剩余时间"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(service.isActive ? (service.endsAt == nil ? T("永不") : service.remainingText) : "—")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary.opacity(0.8))
                }
            }
        }
    }

    private func row(_ title: String, _ value: String, ok: Bool) -> some View {
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
                .foregroundStyle(Color.primary.opacity(0.8))
        }
    }

    private func localized(_ duration: EnergyService.Duration) -> String {
        switch duration {
        case .min15: return "15 \(T("分钟"))"
        case .min30: return "30 \(T("分钟"))"
        case .hour1: return "1 \(T("小时"))"
        case .hour2: return "2 \(T("小时"))"
        case .forever: return T("永不")
        case .off: return T("关闭")
        }
    }
}
