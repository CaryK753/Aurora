import SwiftUI

struct TrackpadView: View {
    @ObservedObject var service: TrackpadService
    @State private var speed = 1.0
    var body: some View {
        VStack(spacing: 12) {
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: T("触控板"), symbol: "hand.draw")
                    Text(T(service.deviceName)).font(.callout).foregroundStyle(.secondary)
                    Button(T("打开系统完整触控板设置")) { service.openSettings() }
                        .buttonStyle(SoftButtonStyle())
                    Text(T("手势会直接修改系统设置；系统完整设置中可进一步选择手指数、拖移方式与手势演示。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = service.message { Text(message).font(.caption).foregroundStyle(AuroraTheme.warn) }
                }
            }
            ForEach(TrackpadOption.Section.allCases, id: \.self) { section in
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: T(section.rawValue), symbol: "hand.point.up.left")
                        if section == .point {
                            HStack {
                                Text(T("跟踪速度")).font(.caption)
                                Slider(value: $speed, in: 0...3, onEditingChanged: { editing in
                                    if !editing { service.setTrackingSpeed(speed) }
                                })
                            }
                        }
                        ForEach(TrackpadOption.all.filter { $0.section == section }) { option in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(T(option.title)).font(.system(size: 11))
                                    Spacer()
                                    Picker(T(option.title), selection: Binding(
                                        get: { service.choices[option.id] ?? 0 },
                                        set: { service.set(option, choice: $0) }
                                    )) {
                                        ForEach(option.choices.indices, id: \.self) { index in
                                            Text(T(option.choices[index])).tag(index)
                                        }
                                    }
                                    .labelsHidden().frame(width: 138)
                                }
                                if let note = option.note { Text(T(note)).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        if section == .access {
                            Button(T("更多拖移选项与辅助功能")) { service.openSettings(accessibility: true) }
                                .buttonStyle(SoftButtonStyle())
                        }
                    }
                }
                .disabled(!service.hasHardware || service.isApplying)
            }
        }
        .onAppear { service.refresh(); speed = service.trackingSpeed }
        .onChange(of: service.trackingSpeed) { _, value in speed = value }
    }
}
