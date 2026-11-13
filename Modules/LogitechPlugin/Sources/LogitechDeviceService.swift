import Combine
import Foundation

@MainActor
public final class LogitechDeviceService: ObservableObject {
    @Published public private(set) var isAvailable = false
    @Published public private(set) var devices: [LogitechDevice] = []
    /// 曾经检测到过的罗技设备；鼠标离线后依然保留，插件不会被隐藏或关闭
    @Published public private(set) var knownDevices: [LogitechKnownDevice] = []
    @Published public private(set) var profiles: [LogitechProfile] = []
    @Published public private(set) var bindings: [String: [String: String]] = [:]
    /// 每个设备选定的默认方案（设备 id → 方案 id），重连后自动套用
    @Published public private(set) var defaultProfiles: [String: UUID] = [:]
    @Published public private(set) var isBusy = false
    @Published public private(set) var isEnabled: Bool = false
    @Published public var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            defaults.set(selectedID, forKey: "logitech.selectedID")
        }
    }
    @Published public private(set) var message: String?
    @Published public private(set) var activeProfile: UUID?
    @Published public private(set) var lastButton: String?
    /// 需要引导用户配置的设备；界面监听它来弹设置向导
    @Published public private(set) var pendingSetup: LogitechKnownDevice?
    public var onAction: ((String) -> Void)?
    private let worker: LogitechWorker
    private let defaults: UserDefaults
    private let availabilityProvider: () -> Bool
    private var timer: Timer?
    private var generation = 0
    private var moduleEnabled = true
    private var preferredEnabled: Bool
    private var owned = Set<String>()
    /// 本次连接里已经套用过默认方案的设备，避免每次刷新都重放一遍
    private var autoApplied = Set<String>()
    private var setupDone = Set<String>()

    public init(defaults: UserDefaults = .standard, autoConnect: Bool = true, availabilityProvider: (() -> Bool)? = nil) {
        self.defaults = defaults
        self.availabilityProvider = availabilityProvider ?? { !LogitechDiscovery.candidates().isEmpty }
        worker = LogitechWorker(defaults: defaults)
        preferredEnabled = defaults.object(forKey: "logitech.enabled") as? Bool ?? true
        isAvailable = self.availabilityProvider()
        // 启用状态只取决于用户的选择：鼠标离线也保持启用，下次连上自动接管
        isEnabled = preferredEnabled
        if let data = defaults.data(forKey: "logitech.profiles"), let saved = try? JSONDecoder().decode([LogitechProfile].self, from: data) { profiles = saved }
        if let data = defaults.data(forKey: "logitech.knownDevices"), let saved = try? JSONDecoder().decode([LogitechKnownDevice].self, from: data) { knownDevices = saved }
        setupDone = Set(defaults.stringArray(forKey: "logitech.setupDone") ?? [])
        if let saved = defaults.dictionary(forKey: "logitech.defaultProfiles") as? [String: String] {
            defaultProfiles = saved.compactMapValues(UUID.init(uuidString:))
        }
        selectedID = defaults.string(forKey: "logitech.selectedID")
        bindings = defaults.object(forKey: "logitech.bindings") as? [String: [String: String]] ?? [:]
        worker.buttonHandler = { [weak self] id, cid in
            Task { @MainActor in
                guard let self, self.isEnabled, self.moduleEnabled, self.owned.contains("\(id):\(cid)"),
                      self.devices.first(where: { $0.id == id })?.buttons.first(where: { $0.id == cid })?.diverted == true else { return }
                self.lastButton = self.devices.first(where: { $0.id == id })?.buttons.first(where: { $0.id == cid })?.name
                if let action = self.bindings[id]?[String(cid)], action != "none" {
                    if self.selectedID != id { self.selectedID = id; self.activeProfile = nil }
                    self.handleAction(action)
                }
            }
        }
        // 启动时先登记一次已经插着的设备，向导窗口才会在首次发现时弹出来
        refreshKnownDevices()
        if autoConnect {
            timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.updateAvailability()
                    guard self.isEnabled, self.moduleEnabled, !self.isBusy else { return }
                    if self.isAvailable {
                        if self.devices.isEmpty { self.connect() } else { self.refresh() }
                    }
                }
            }
            if isEnabled && isAvailable { connect() }
        }
    }
    deinit { timer?.invalidate(); let worker = worker; worker.queue.async { worker.disconnect() } }

    // MARK: - 设备记忆

    /// 插件是否值得出现在鼠标页：连着、见过、或存过方案都算
    public var showsCard: Bool { isAvailable || !knownDevices.isEmpty || !profiles.isEmpty }
    /// 鼠标此刻是否在线
    public var isOnline: Bool { !devices.isEmpty }
    public var hasKnownDevices: Bool { !knownDevices.isEmpty }
    /// 离线时用来展示方案的设备（上次选中的那只）
    public var rememberedDeviceID: String? { selectedDevice?.id ?? selectedID ?? knownDevices.first?.id }
    public func knownDevice(for id: String?) -> LogitechKnownDevice? {
        guard let id else { return nil }
        return knownDevices.first { $0.id == id } ?? knownDevices.first
    }

    /// 检测到设备后弹一次设置向导；同一只鼠标只提示一次
    public func requestSetup(_ device: LogitechKnownDevice? = nil) {
        let target = device ?? pendingSetup ?? knownDevices.first
        guard let target else { return }
        pendingSetup = target
    }
    public func markSetupDone(_ identity: String? = nil) {
        let key = identity ?? pendingSetup?.identity
        if let key { setupDone.insert(key); defaults.set(Array(setupDone), forKey: "logitech.setupDone") }
        pendingSetup = nil
    }
    public func dismissSetup() { markSetupDone() }

    private func refreshKnownDevices() {
        let candidates = LogitechDiscovery.candidates()
        guard !candidates.isEmpty else { return }
        var updated = knownDevices
        var changed = false
        for candidate in candidates {
            if let index = updated.firstIndex(where: { $0.identity == candidate.identity }) {
                if updated[index].id != candidate.id { updated[index].id = candidate.id; changed = true }
                if updated[index].name != candidate.name { updated[index].name = candidate.name; changed = true }
                if updated[index].transport != candidate.transport { updated[index].transport = candidate.transport; changed = true }
            } else {
                let entry = LogitechKnownDevice(
                    id: candidate.id,
                    name: candidate.name,
                    transport: candidate.transport,
                    identity: candidate.identity
                )
                updated.append(entry)
                changed = true
                if !setupDone.contains(entry.identity) { pendingSetup = entry }
            }
        }
        if changed {
            knownDevices = updated
            if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: "logitech.knownDevices") }
        }
    }

    // MARK: - 默认方案

    public func defaultProfileID(for deviceID: String) -> UUID? { defaultProfiles[deviceID] }
    public var selectedDefaultProfileID: UUID? { selectedDevice.flatMap { defaultProfiles[$0.id] } }
    public func isDefaultProfile(_ id: UUID, deviceID: String? = nil) -> Bool {
        guard let deviceID = deviceID ?? selectedDevice?.id else { return false }
        return defaultProfiles[deviceID] == id
    }
    public func setDefaultProfile(_ id: UUID?, for deviceID: String? = nil) {
        guard let deviceID = deviceID ?? selectedDevice?.id else { return }
        if let id, profiles.contains(where: { $0.id == id && $0.deviceID == deviceID }) {
            defaultProfiles[deviceID] = id
            message = "已设为默认方案，连接这台鼠标时会自动套用"
        } else {
            defaultProfiles.removeValue(forKey: deviceID)
            message = "已取消默认方案"
        }
        autoApplied.remove(deviceID)
        persistDefaults()
    }

    private func persistDefaults() {
        defaults.set(defaultProfiles.mapValues(\.uuidString), forKey: "logitech.defaultProfiles")
    }

    private func handleAction(_ action: String) {
        guard let device = selectedDevice else { return }
        switch action {
        case "plugin.cycleProfile":
            let candidates = profiles.filter { $0.deviceID == device.id }
            guard !candidates.isEmpty else { message = "请先保存鼠标方案"; return }
            let index = candidates.firstIndex(where: { $0.id == activeProfile }).map { ($0 + 1) % candidates.count } ?? 0
            applyProfile(candidates[index].id)
        case "plugin.cycleDPI":
            let saved = profiles.filter { $0.deviceID == device.id }.compactMap(\.dpi)
            let values = Array(Set(saved.isEmpty ? [800, 1600, 3200].filter { device.supportedDPI.contains($0) } : saved)).sorted()
            guard !values.isEmpty else { message = "当前设备没有可切换的 DPI 档位"; return }
            let index = values.firstIndex(of: device.dpi ?? 0).map { ($0 + 1) % values.count } ?? 0
            setDPI(values[index])
        case "plugin.toggleWheel":
            let current = LogitechWheelChoice.current(device)
            let next = LogitechWheelChoice(rawValue: (current.rawValue + 1) % 3) ?? .automatic
            setWheel(next)
        default: onAction?(action)
        }
    }

    private func updateAvailability() {
        let available = availabilityProvider()
        isAvailable = available
        if available {
            refreshKnownDevices()
        } else if !devices.isEmpty {
            disconnect()
        }
    }

    /// 原生事件在 session tap 处理，优先于普通全局映射，吞掉配对的按下和抬起。
    public func handleNativeButton(_ button: Int) -> Bool {
        guard isEnabled, moduleEnabled else { return false }
        for device in devices {
            guard let control = device.buttons.first(where: {
                LogitechButtonPolicy.nativeButton(cid: $0.id, transport: device.transport) == button
            }), owned.contains("\(device.id):\(control.id)"),
                  let action = bindings[device.id]?[String(control.id)], action != "none" else { continue }
            selectedID = device.id
            lastButton = control.name
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled, self.moduleEnabled else { return }
                self.selectedID = device.id
                self.handleAction(action)
            }
            return true
        }
        return false
    }

    public func isMappingActive(_ cid: UInt16, deviceID: String) -> Bool {
        guard isEnabled, moduleEnabled, owned.contains("\(deviceID):\(cid)"),
              let device = devices.first(where: { $0.id == deviceID }) else { return false }
        return LogitechButtonPolicy.nativeButton(cid: cid, transport: device.transport) != nil
            || device.buttons.first(where: { $0.id == cid })?.diverted == true
    }
    public var selectedDevice: LogitechDevice? { devices.first(where: { $0.id == selectedID }) ?? devices.first }
    public func setEnabled(_ enabled: Bool) {
        preferredEnabled = enabled
        isEnabled = enabled; defaults.set(enabled, forKey: "logitech.enabled")
        if isEnabled && moduleEnabled && isAvailable { connect() } else { disconnect() }
    }
    public func setModuleEnabled(_ enabled: Bool) {
        guard enabled != moduleEnabled else { return }
        moduleEnabled = enabled
        if enabled && isEnabled { connect() } else { disconnect() }
    }
    public func connect() {
        guard isEnabled, moduleEnabled, !isBusy else { return }
        generation += 1; let token = generation
        isBusy = true; message = nil; owned.removeAll(); autoApplied.removeAll()
        let worker = worker
        worker.queue.async { [weak self] in
            let (devices, errors) = worker.connect()
            Task { @MainActor in
                guard let self, token == self.generation else { return }
                self.devices = devices; self.isBusy = false
                for device in devices {
                    for button in device.buttons where LogitechButtonPolicy.nativeButton(cid: button.id, transport: device.transport) != nil && !button.diverted {
                        if let action = self.bindings[device.id]?[String(button.id)], action != "none" {
                            self.owned.insert("\(device.id):\(button.id)")
                        }
                    }
                }
                if self.selectedID == nil || !devices.contains(where: { $0.id == self.selectedID }) { self.selectedID = devices.first?.id }
                self.message = errors.isEmpty ? (devices.isEmpty ? "未发现可连接的罗技 HID++ 鼠标，请唤醒设备并检查输入监控权限" : nil) : errors.joined(separator: "\n")
                self.autoApplyDefaultProfiles()
            }
        }
    }
    private func disconnect() {
        generation += 1; devices = []; owned.removeAll(); isBusy = false; activeProfile = nil; autoApplied.removeAll()
        let worker = worker; worker.queue.async { worker.disconnect() }
    }
    public func reset() {
        disconnect()
        profiles = []; bindings = [:]; selectedID = nil
        defaultProfiles = [:]
        // 设备记忆保留：重置只清配置，不把「见过这只鼠标」也一并抹掉
        defaults.removeObject(forKey: "logitech.profiles")
        defaults.removeObject(forKey: "logitech.bindings")
        defaults.removeObject(forKey: "logitech.defaultProfiles")
        preferredEnabled = true; isEnabled = true; defaults.set(true, forKey: "logitech.enabled")
        isAvailable = availabilityProvider()
        if moduleEnabled && isAvailable { refreshKnownDevices(); connect() }
    }

    public func shutdown() {
        timer?.invalidate(); generation += 1; owned.removeAll()
        let worker = worker
        let done = DispatchSemaphore(value: 0)
        worker.queue.async { worker.disconnect(); done.signal() }
        _ = done.wait(timeout: .now() + 3)
    }
    public func refresh() {
        perform { worker in _ = worker.refresh() }
    }
    public func setDPI(_ value: Int) { guard let id = selectedDevice?.id else { return }; change { try $0.session(id).setDPI(value) } }
    public func setWheel(_ choice: LogitechWheelChoice, threshold: Int? = nil, torque: Int? = nil) {
        guard let id = selectedDevice?.id else { return }
        change { try $0.session(id).setWheel(choice, threshold: threshold, torque: torque) }
    }
    public func setHighResolution(_ enabled: Bool) {
        guard let id = selectedDevice?.id else { return }; change { try $0.session(id).setHighResolution(enabled) }
    }
    private func change(_ operation: @escaping (LogitechWorker) throws -> Void) {
        perform(operation) { [weak self] in self?.activeProfile = nil }
    }
    public func setBinding(_ cid: UInt16, action: String) {
        guard let id = selectedDevice?.id else { return }
        let enabled = !action.isEmpty && action != "none"
        perform({ worker in
            let session = try worker.session(id)
            if LogitechButtonPolicy.nativeButton(cid: cid, transport: session.state.transport) != nil {
                if session.originalDiversion[cid] != nil { try session.setDiversion(cid, enabled: false) }
                else if session.state.buttons.first(where: { $0.id == cid })?.diverted == true {
                    throw LogitechFailure.unavailable("此标准按键已被其他驱动接管，请先恢复默认")
                }
            } else { try session.setDiversion(cid, enabled: enabled) }
        }) { [weak self] in
            guard let self else { return }
            self.bindings[id, default: [:]][String(cid)] = enabled ? action : nil
            if enabled { self.owned.insert("\(id):\(cid)") } else { self.owned.remove("\(id):\(cid)") }
            self.defaults.set(self.bindings, forKey: "logitech.bindings")
            self.activeProfile = nil
        }
    }
    public func restoreSavedBindings() {
        guard let device = selectedDevice else { return }
        let profile = LogitechProfile(name: "saved", device: device, bindings: bindings[device.id] ?? [:])
        applyValues(profile, id: nil)
    }
    public func saveProfile(name: String) {
        guard !isBusy, let device = selectedDevice else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { message = "请输入 1–60 个字符的方案名称"; return }
        let profile = LogitechProfile(name: name, device: device, bindings: bindings[device.id] ?? [:])
        profiles.append(profile); persistProfiles(); message = "已保存当前设备设置"; activeProfile = profile.id
    }
    public func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        let stale = defaultProfiles.filter { $0.value == id }.map(\.key)
        if !stale.isEmpty { for key in stale { defaultProfiles.removeValue(forKey: key) }; persistDefaults() }
        persistProfiles(); if activeProfile == id { activeProfile = nil }
    }
    public func applyProfile(_ id: UUID) { applyProfile(id, completion: nil) }
    private func applyProfile(_ id: UUID, completion: ((Bool) -> Void)?) {
        guard let profile = profiles.first(where: { $0.id == id }), profile.deviceID == selectedDevice?.id else {
            message = "此方案不属于当前鼠标"; completion?(false); return
        }
        applyValues(profile, id: id, completion: completion)
    }
    private func applyValues(_ profile: LogitechProfile, id: UUID?, completion: ((Bool) -> Void)? = nil) {
        let previous = bindings[profile.deviceID] ?? [:]
        perform({ try $0.apply(profile, previousBindings: previous) }, success: { [weak self] in
            guard let self else { completion?(true); return }
            self.bindings[profile.deviceID] = profile.bindings
            for button in self.devices.first(where: { $0.id == profile.deviceID })?.buttons ?? [] {
                let key = "\(profile.deviceID):\(button.id)"
                if profile.bindings[String(button.id)] != nil && (button.diverted || LogitechButtonPolicy.nativeButton(cid: button.id, transport: self.devices.first(where: { $0.id == profile.deviceID })?.transport ?? "") != nil) { self.owned.insert(key) } else { self.owned.remove(key) }
            }
            self.defaults.set(self.bindings, forKey: "logitech.bindings")
            self.activeProfile = id; self.message = "方案已应用并读回验证"
            completion?(true)
        }, failure: { _ in completion?(false) })
    }
    private func persistProfiles() { if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "logitech.profiles") } }

    /// 连接后把设备选定的默认方案自动套上去（每只鼠标每次连接只做一次）
    private func autoApplyDefaultProfiles() {
        let targets: [(id: String, profile: UUID)] = devices.compactMap { device in
            guard let profileID = defaultProfiles[device.id],
                  profiles.contains(where: { $0.id == profileID && $0.deviceID == device.id }),
                  !autoApplied.contains(device.id) else { return nil }
            return (device.id, profileID)
        }
        guard !targets.isEmpty else { return }
        applyDefaultProfiles(targets, at: 0)
    }
    private func applyDefaultProfiles(_ targets: [(id: String, profile: UUID)], at index: Int) {
        guard index < targets.count, isEnabled, moduleEnabled else { return }
        let target = targets[index]
        if selectedID != target.id { selectedID = target.id; activeProfile = nil }
        applyProfile(target.profile) { [weak self] applied in
            guard let self else { return }
            if applied { self.autoApplied.insert(target.id) }
            self.applyDefaultProfiles(targets, at: index + 1)
        }
    }

    private func perform(
        _ operation: @escaping (LogitechWorker) throws -> Void,
        success: @escaping () -> Void = {},
        failure: ((String) -> Void)? = nil
    ) {
        guard isEnabled, moduleEnabled, !isBusy else { failure?(message ?? ""); return }
        isBusy = true; message = nil
        let worker = worker; let token = generation
        worker.queue.async { [weak self] in
            var error: String?
            do { try operation(worker) } catch let failure { error = failure.localizedDescription; _ = worker.refresh() }
            let snapshot = worker.snapshot()
            Task { @MainActor in
                guard let self, token == self.generation else { return }
                self.devices = snapshot; self.isBusy = false
                if let error { self.message = error; self.activeProfile = nil; failure?(error) } else { success() }
            }
        }
    }
}
