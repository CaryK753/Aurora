import SwiftUI
import LogitechPlugin

struct LogitechHardwareSettings: View {
    @ObservedObject var service: LogitechDeviceService
    let device: LogitechDevice
    @State private var dpiIndex = 0.0
    @State private var threshold = 30.0
    @State private var torque = 50.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let dpi = device.dpi {
                if device.supportedDPI.count > 1 {
                    HStack {
                        Text("DPI").font(.caption)
                        Slider(value: $dpiIndex, in: 0...Double(device.supportedDPI.count - 1), step: 1) { editing in
                            if !editing { service.setDPI(device.supportedDPI[min(max(Int(dpiIndex), 0), device.supportedDPI.count - 1)]) }
                        }
                        Text("\(device.supportedDPI[min(max(Int(dpiIndex), 0), device.supportedDPI.count - 1)])")
                            .font(.caption.monospacedDigit()).frame(width: 45, alignment: .trailing)
                    }
                } else { Text("DPI · \(dpi)").font(.caption) }
                Text(T("硬件 DPI 与 Aurora 指针倍率会叠加，方案只调整这台鼠标。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if device.wheelMode != nil {
                Picker(T("MagSpeed 滚轮"), selection: Binding(
                    get: { LogitechWheelChoice.current(device) }, set: { service.setWheel($0) }
                )) {
                    ForEach(LogitechWheelChoice.allCases) { Text(T($0.title)).tag($0) }
                }
                if LogitechWheelChoice.current(device) == .automatic {
                    HStack {
                        Text(T("切换阈值")).font(.caption)
                        Slider(value: $threshold, in: 1...50, step: 1) { editing in
                            if !editing { service.setWheel(.automatic, threshold: Int(threshold)) }
                        }
                        Text("\(Int(threshold))").font(.caption.monospacedDigit()).frame(width: 26)
                    }
                }
                if device.supportsTorque, device.torque != nil {
                    HStack {
                        Text(T("分段阻尼")).font(.caption)
                        Slider(value: $torque, in: 1...100, step: 1) { editing in
                            if !editing { service.setWheel(LogitechWheelChoice.current(device), torque: Int(torque)) }
                        }
                        Text("\(Int(torque))%").font(.caption.monospacedDigit()).frame(width: 35)
                    }
                }
            }
            if let high = device.highResolution {
                Toggle(T("高分辨率滚轮"), isOn: Binding(get: { high }, set: { service.setHighResolution($0) }))
                    .toggleStyle(.switch).controlSize(.small).font(.caption)
            }
            if device.dpi == nil && device.wheelMode == nil && device.highResolution == nil {
                Text(T("此设备未报告可用的硬件调节功能。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(service.isBusy)
        .onAppear { synchronize() }
        .onChange(of: device) { _, _ in synchronize() }
    }

    private func synchronize() {
        dpiIndex = Double(device.supportedDPI.firstIndex(of: device.dpi ?? 0) ?? 0)
        threshold = Double(min(max(device.smartShiftThreshold ?? 30, 1), 50))
        torque = Double(device.torque ?? 50)
    }
}
