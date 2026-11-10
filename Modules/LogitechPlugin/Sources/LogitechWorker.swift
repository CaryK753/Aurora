import Foundation

final class LogitechWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.cary.aurora.logitech", qos: .userInitiated)
    private var connections: [LogitechHIDTransport] = []
    let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    var sessions: [String: LogitechSession] = [:]
    var buttonHandler: ((String, UInt16) -> Void)?

    func connect() -> ([LogitechDevice], [String]) {
        disconnect()
        var errors: [String] = []
        for candidate in LogitechDiscovery.candidates() {
            let transport = LogitechHIDTransport(device: candidate.device)
            let router = LogitechReportRouter()
            transport.onNotification = { router.receive($0) }
            do { try transport.start() }
            catch { errors.append(candidate.name + "：" + error.localizedDescription); transport.close(); continue }
            var connected = false
            for slot in candidate.isReceiver ? Array(UInt8(1)...UInt8(6)) : [UInt8(0xFF)] {
                do {
                    let id = candidate.id + (candidate.isReceiver ? "-slot\(slot)" : "")
                    let session = LogitechSession(transport: transport,
                        state: LogitechDevice(id: id, name: candidate.name + (candidate.isReceiver ? " · \(slot)" : ""), transport: candidate.transport), deviceIndex: slot)
                    session.onButton = { [weak self] cid in self?.buttonHandler?(id, cid) }
                    try session.discover()
                    guard session.state.features[0x2201] != nil || session.state.features[0x2111] != nil || session.state.features[0x2110] != nil else {
                        throw LogitechFailure.unavailable("此设备不是受支持的罗技鼠标")
                    }
                    session.onLeaseChanged = { [defaults] values in
                        var leases = defaults.object(forKey: "logitech.leases") as? [String: [String: Bool]] ?? [:]
                        leases[id] = Dictionary(uniqueKeysWithValues: values.map { (String($0.key), $0.value) })
                        defaults.set(leases, forKey: "logitech.leases")
                    }
                    let lease = (defaults.object(forKey: "logitech.leases") as? [String: [String: Bool]])?[id] ?? [:]
                    session.originalDiversion = Dictionary(uniqueKeysWithValues: lease.compactMap {
                        guard let key = UInt16($0.key) else { return nil }; return (key, $0.value)
                    })
                    session.restoreButtons()
                    sessions[id] = session
                    router.add(slot) { [weak session] in session?.notification($0) }
                    connected = true
                } catch {
                    if !candidate.isReceiver { errors.append(candidate.name + "：" + error.localizedDescription) }
                }
            }
            if connected { connections.append(transport) } else { transport.close() }
        }
        return (snapshot(), errors)
    }

    func snapshot() -> [LogitechDevice] { sessions.values.map(\.state).sorted { $0.id < $1.id } }
    func disconnect() {
        for session in sessions.values { session.restoreButtons() }
        sessions.removeAll()
        for connection in connections { connection.close() }
        connections.removeAll()
    }
    func refresh() -> [LogitechDevice] {
        for (id, session) in sessions {
            do { try session.refresh() }
            catch { session.restoreButtons(); sessions.removeValue(forKey: id) }
        }
        return snapshot()
    }
    func session(_ id: String) throws -> LogitechSession {
        guard let session = sessions[id] else { throw LogitechFailure.unavailable("鼠标已经断开，请重新连接") }
        return session
    }

    func apply(_ profile: LogitechProfile, previousBindings: [String: String]) throws {
        let session = try session(profile.deviceID)
        for button in session.state.buttons where profile.bindings[String(button.id)] != nil && button.diverted && session.originalDiversion[button.id] == nil {
            throw LogitechFailure.unavailable("某些按键已被其他驱动接管，请先恢复默认")
        }
        let requested = Set(profile.bindings.keys.compactMap(UInt16.init))
        let allowed = Set(session.state.buttons.filter(\.canDivert).map(\.id))
        guard requested.isSubset(of: allowed) else { throw LogitechFailure.unavailable("方案包含当前设备不支持的按键") }
        let owned = Set(session.originalDiversion.keys.map(String.init))
        let active = previousBindings.filter { owned.contains($0.key) }
        let previous = LogitechProfile(name: "rollback", device: session.state, bindings: active)
        do { try applyValues(profile, to: session) }
        catch {
            let primary = error
            do { try applyValues(previous, to: session) }
            catch { throw LogitechFailure.unavailable("方案应用失败，部分设置未能恢复。请查看当前设备值后重试。") }
            throw primary
        }
    }

    private func applyValues(_ profile: LogitechProfile, to session: LogitechSession) throws {
        if let dpi = profile.dpi, dpi != session.state.dpi { try session.setDPI(dpi) }
        if let mode = profile.wheelMode, let threshold = profile.threshold {
            let choice: LogitechWheelChoice = mode == 1 ? .freeSpin : (threshold == 255 ? .ratchet : .automatic)
            try session.setWheel(choice, threshold: threshold, torque: profile.torque)
        }
        if let high = profile.highResolution, high != session.state.highResolution { try session.setHighResolution(high) }
        for button in session.state.buttons where button.canDivert {
            let wants = profile.bindings[String(button.id)].map { !$0.isEmpty && $0 != "none" } ?? false
            if LogitechButtonPolicy.nativeButton(cid: button.id, transport: session.state.transport) != nil {
                if session.originalDiversion[button.id] != nil { try session.setDiversion(button.id, enabled: false) }
                continue
            }
            if wants && !button.diverted { try session.setDiversion(button.id, enabled: true) }
            else if !wants && session.originalDiversion[button.id] != nil {
                try session.setDiversion(button.id, enabled: false)
            }
        }
    }
}
