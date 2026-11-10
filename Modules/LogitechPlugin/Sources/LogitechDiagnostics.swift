import Foundation

public enum LogitechDiagnostics {
    public static func scan(verifyCurrentValues: Bool = false) -> [String] {
        var lines: [String] = []
        for candidate in LogitechDiscovery.candidates() {
            lines.append("\(candidate.name) | \(candidate.transport)")
            let connection = LogitechHIDTransport(device: candidate.device)
            do {
                try connection.start()
                let session = LogitechSession(transport: connection,
                    state: LogitechDevice(id: candidate.id, name: candidate.name, transport: candidate.transport))
                try session.discover()
                if verifyCurrentValues {
                    if let dpi = session.state.dpi { try session.setDPI(dpi); lines.append("✓ DPI 原值写入与读回") }
                    if session.state.wheelMode != nil {
                        try session.setWheel(LogitechWheelChoice.current(session.state), threshold: session.state.smartShiftThreshold,
                                             torque: session.state.torque)
                        lines.append("✓ 滚轮模式、SmartShift、阻尼原值写入与读回")
                    }
                    if let high = session.state.highResolution { try session.setHighResolution(high); lines.append("✓ 高分辨率模式原值写入与读回") }
                    if let button = session.state.buttons.first(where: { $0.canDivert && !$0.diverted && $0.id == 0xC4 }) {
                        do {
                            try session.setDiversion(button.id, enabled: true)
                            try session.setDiversion(button.id, enabled: false)
                            lines.append("✓ 模式切换键临时接管和恢复读回")
                        } catch { session.restoreButtons(); throw error }
                    }
                }
                let state = session.state
                lines.append("features=" + state.features.keys.sorted().map { String(format: "%04X", $0) }.joined(separator: ","))
                lines.append("dpi=\(String(describing: state.dpi)) steps=\(state.supportedDPI.count) mode=\(String(describing: state.wheelMode)) threshold=\(String(describing: state.smartShiftThreshold)) torque=\(String(describing: state.torque))")
                lines.append("buttons=" + state.buttons.map { String(format: "%04X", $0.id) + " \($0.name) divertable=\($0.canDivert) diverted=\($0.diverted)" }.joined(separator: "; "))
            } catch { lines.append("error: \(error.localizedDescription)") }
            connection.close()
        }
        return lines.isEmpty ? ["未发现罗技 HID++ 接口"] : lines
    }
}
