//  AudioView.swift
//  Aurora — 声音输出/输入设备管理

import SwiftUI

struct AudioView: View {
    @ObservedObject var service: AudioService
    @ObservedObject var perApp: PerAppAudioService
    @ObservedObject var state: AppState

    init(state: AppState) {
        self.state = state
        self.service = state.audio
        self.perApp = state.appAudio
    }

    private var currentOutput: AudioDeviceInfo? {
        service.outputs.first(where: \.isDefault) ?? service.outputs.first
    }

    var body: some View {
        VStack(spacing: 12) {
            if let device = currentOutput {
                currentCard(device)
            }
            appVolumeCard
            outputsCard
            inputsCard
        }
    }

    private func isSilent(_ device: AudioDeviceInfo) -> Bool {
        device.isMuted || (device.hasVolume && device.volume <= 0.001)
    }

    private func speakerSymbol(_ volume: Double) -> String {
        switch volume {
        case ..<0.001: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private func currentCard(_ device: AudioDeviceInfo) -> some View {
        GlassCard(padding: 16) {
            VStack(spacing: 12) {
                HStack(spacing: 11) {
                    IconBadge(symbol: isSilent(device) ? "speaker.slash.fill" : speakerSymbol(device.volume), size: 34, style: .tinted)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(1)
                        Text("\(T("当前输出")) · \(device.transport)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    Button {
                        service.toggleMute(device)
                        state.showToast(isSilent(device) ? T("启用") : T("静音"), symbol: "speaker.slash")
                    } label: {
                        Image(systemName: isSilent(device) ? "speaker.slash.fill" : speakerSymbol(device.volume))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isSilent(device) ? AnyShapeStyle(AuroraTheme.warn) : AnyShapeStyle(Color.secondary))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }

                if device.hasVolume {
                    HStack(spacing: 9) {
                        Image(systemName: "speaker.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        AuroraSlider(
                            value: Binding(
                                get: { device.volume },
                                set: { service.setVolume($0, for: device) }
                            )
                        )
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(Fmt.percent(device.volume))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                } else {
                    Text(T("该设备不支持系统音量控制"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var appVolumeCard: some View {
        GlassCard(padding: 11) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    SectionLabel(text: T("按应用调节"), symbol: "slider.vertical.3")
                    Text("\(perApp.items.count)")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if perApp.controlledCount > 0 {
                        Text(TF("%d 个已接管", perApp.controlledCount))
                            .font(.system(size: 8.5))
                            .foregroundStyle(AuroraTheme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(AuroraTheme.accent.opacity(0.12)))
                    }
                    if perApp.items.contains(where: { abs($0.volume - 1) > 0.001 }) {
                        Button {
                            perApp.resetAll()
                            state.showToast(T("已恢复全部应用音量"), symbol: "arrow.counterclockwise")
                        } label: {
                            Text(T("全部复位"))
                                .font(.system(size: 8.5))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !perApp.isSupported {
                    Text(T("当前系统版本不支持按应用调节音量"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                } else if perApp.items.isEmpty {
                    Text(T("暂无正在发声的应用，播放点声音就会出现"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 2) {
                            ForEach(perApp.items) { item in
                                appVolumeRow(item)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: perApp.items.count > 4 ? 188 : nil)
                }

                if let error = perApp.lastError {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(AuroraTheme.warn)
                }

                Text(T("100% 走系统原生通路；调低后在本地重新混音，不改变系统默认输出设备"))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func appVolumeRow(_ item: AppAudioItem) -> some View {
        // 用实时值而不是 2 秒前的快照：拖到 0 时喇叭图标立刻变成静音，不会被误读成「卡住了」
        let live = perApp.volume(for: item.id)
        return HStack(alignment: .center, spacing: 7) {
            appIcon(item)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.name)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Fmt.percent(live))
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(item.isControlled ? AnyShapeStyle(AuroraTheme.accent) : AnyShapeStyle(Color.secondary))
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)

                    Button {
                        perApp.toggleMute(item.id)
                    } label: {
                        Image(systemName: live <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(live <= 0.001 ? AnyShapeStyle(AuroraTheme.warn) : AnyShapeStyle(Color.secondary))
                            .frame(width: 18, height: 16)
                    }
                    .buttonStyle(.plain)
                }

                AuroraSlider(
                    value: Binding(
                        get: { perApp.volume(for: item.id) },
                        set: { perApp.setVolume($0, for: item.id) }
                    ),
                    range: 0...1.5,
                    trackHeight: 3.5
                )
                .frame(height: 18)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func appIcon(_ item: AppAudioItem) -> some View {
        if let app = NSRunningApplication(processIdentifier: item.pid), let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 15, height: 15)
        } else {
            // 命令行工具（say / afplay）没有 App 图标，用波形徽标占位，比空虚线框更像「在发声」
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(AuroraTheme.accent.opacity(0.14))
                .frame(width: 15, height: 15)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(AuroraTheme.accent)
                }
        }
    }

    private var outputsCard: some View {
        GlassCard(padding: 10) {
            VStack(spacing: 0) {
                HStack {
                    SectionLabel(text: T("输出设备"), symbol: "hifispeaker")
                    Spacer()
                    Text("\(service.outputs.count)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)

                if service.outputs.isEmpty {
                    EmptyHint(symbol: "speaker.slash", text: T("未找到音频设备"))
                } else {
                    ForEach(Array(service.outputs.enumerated()), id: \.element.id) { index, device in
                        deviceRow(device)
                        if index < service.outputs.count - 1 {
                            Rectangle().fill(Color.primary.opacity(0.055)).frame(height: 0.6).padding(.leading, 34)
                        }
                    }
                }
            }
        }
    }

    private var inputsCard: some View {
        GlassCard(padding: 10) {
            VStack(spacing: 0) {
                HStack {
                    SectionLabel(text: T("输入设备"), symbol: "mic")
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)

                if service.inputs.isEmpty {
                    EmptyHint(symbol: "mic.slash", text: T("未找到音频设备"))
                } else {
                    ForEach(Array(service.inputs.enumerated()), id: \.element.id) { index, device in
                        deviceRow(device)
                        if index < service.inputs.count - 1 {
                            Rectangle().fill(Color.primary.opacity(0.055)).frame(height: 0.6).padding(.leading, 34)
                        }
                    }
                }
            }
        }
    }

    private func deviceRow(_ device: AudioDeviceInfo) -> some View {
        HStack(spacing: 9) {
            IconBadge(
                symbol: device.isOutput ? "hifispeaker.fill" : "mic.fill",
                size: 24,
                style: device.isDefault ? .solid : .tinted
            )

            VStack(alignment: .leading, spacing: 1.5) {
                Text(device.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(device.transport)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if device.isDefault {
                Text(T("默认"))
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(AuroraTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(AuroraTheme.accent.opacity(0.14)))
            } else {
                Button {
                    let succeeded = service.setDefault(device)
                    let title = device.isOutput ? T("已切换默认输出") : T("已切换默认输入")
                    state.showToast(succeeded ? title : T("音频设备切换失败"),
                                    symbol: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle")
                } label: {
                    Text(T("设为默认"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}
