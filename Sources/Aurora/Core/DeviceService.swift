//  DeviceService.swift
//  Aurora — 外部设备：蓝牙 + USB + 外接存储
//
//  数据来源：
//  · system_profiler SPBluetoothDataType -json —— 已连接/已配对的蓝牙设备、电量（含左右耳与充电盒）
//  · system_profiler SPUSBDataType -json —— 有线设备
//  · xcrun devicectl list devices —— iPhone / iPad 的真实型号（系统只在 Xcode 设备层暴露）
//  · mountedVolumeURLs —— 外接磁盘容量

import AppKit
import Combine
import Foundation

struct ExternalDevice: Identifiable, Equatable {
    enum Kind {
        case iPhone, iPad, watch, airPods, headphones, keyboard, mouse, trackpad, storage, usb, other
    }

    struct BatteryPart: Equatable, Identifiable {
        let id = UUID()
        let label: String
        let level: Int
    }

    let id: String
    var name: String
    var kind: Kind
    var isApple: Bool
    var connection: String
    var model: String?
    var detail: String?
    var battery: Int?
    var batteryParts: [BatteryPart] = []
    var charging: Bool = false
    var storageTotal: UInt64?
    var storageUsed: UInt64?
    var online: Bool = true

    var symbol: String {
        switch kind {
        case .iPhone: return "iphone"
        case .iPad: return "ipad"
        case .watch: return "applewatch"
        case .airPods: return "airpodspro"
        case .headphones: return "headphones"
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .storage: return "externaldrive.fill"
        case .usb: return "cable.connector"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    var kindLabel: String {
        switch kind {
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        case .watch: return T("手表")
        case .airPods: return "AirPods"
        case .headphones: return T("耳机")
        case .keyboard: return T("键盘")
        case .mouse: return T("鼠标")
        case .trackpad: return T("触控板")
        case .storage: return T("存储")
        case .usb: return "USB"
        case .other: return T("设备")
        }
    }
}

@MainActor
final class DeviceService: ObservableObject {
    @Published private(set) var devices: [ExternalDevice] = []
    @Published private(set) var lastScan = Date()

    private var timer: Timer?
    private var scanning = false

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let devices = Self.collect()
            Task { @MainActor in
                guard let self else { return }
                self.devices = devices
                self.lastScan = Date()
                self.scanning = false
            }
        }
    }

    var connectedCount: Int { devices.filter(\.online).count }

    // MARK: - 采集

    private nonisolated static func collect() -> [ExternalDevice] {
        var result: [ExternalDevice] = []
        let models = devicectlModels()
        var bluetooth = bluetoothDevices(models: models)
        if !bluetooth.contains(where: { $0.kind == .iPhone }), let model = models["iPhone"] {
            bluetooth.append(
                ExternalDevice(
                    id: "iphone-devicectl",
                    name: model,
                    kind: .iPhone,
                    isApple: true,
                    connection: T("已配对"),
                    model: model,
                    detail: nil,
                    online: false
                )
            )
        }
        result.append(contentsOf: bluetooth)
        result.append(contentsOf: usbDevices(excluding: Set(result.map(\.name))))
        result.append(contentsOf: externalVolumes())
        return result
    }

    // MARK: - 蓝牙

    private nonisolated static func bluetoothDevices(models: [String: String]) -> [ExternalDevice] {
        guard let data = run("/usr/sbin/system_profiler", ["-json", "SPBluetoothDataType"]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        var devices: [ExternalDevice] = []
        for block in blocks {
            if let connected = block["device_connected"] as? [[String: Any]] {
                for entry in connected {
                    for (name, raw) in entry {
                        guard let props = raw as? [String: Any] else { continue }
                        devices.append(makeBluetooth(name: name, props: props, models: models))
                    }
                }
            }
            // 已配对的 iPhone / iPad / Watch 即使不在身边也值得显示，其它离线配件就不占位了
            // 不同 macOS 版本这里是 device_not_connected / device_notConnected
            let offlineList = (block["device_not_connected"] as? [[String: Any]])
                ?? (block["device_notConnected"] as? [[String: Any]])
            if let offline = offlineList {
                for entry in offline {
                    for (name, raw) in entry {
                        guard let props = raw as? [String: Any] else { continue }
                        let device = makeBluetooth(name: name, props: props, models: models, online: false)
                        guard device.kind == .iPhone || device.kind == .iPad || device.kind == .watch else { continue }
                        devices.append(device)
                    }
                }
            }
        }
        return devices
    }

    private nonisolated static func makeBluetooth(
        name: String,
        props: [String: Any],
        models: [String: String],
        online: Bool = true
    ) -> ExternalDevice {
        let vendor = (props["device_vendorID"] as? String) ?? ""
        let minor = ((props["device_minorType"] as? String) ?? "").lowercased()
        let isApple = vendor.contains("Apple") || vendor.hasPrefix("0x004C") || vendor.hasPrefix("0x4C")
        let lowerName = name.lowercased()

        var kind: ExternalDevice.Kind = .other
        if minor.contains("mouse") { kind = .mouse }
        else if minor.contains("keyboard") { kind = .keyboard }
        else if minor.contains("trackpad") { kind = .trackpad }
        else if minor.contains("headphone") {
            if isApple { kind = .airPods } else { kind = .headphones }
        } else if lowerName.contains("iphone") { kind = .iPhone }
        else if lowerName.contains("ipad") { kind = .iPad }
        else if lowerName.contains("watch") { kind = .watch }

        // AirPods 具体系列：名字里带 Pro / Max 的按图标区分
        if kind == .airPods {
            if lowerName.contains("max") { kind = .airPods }
        }

        var battery: Int?
        if let value = props["device_batteryLevel"] as? String {
            battery = Int(value.replacingOccurrences(of: "%", with: ""))
        }
        var parts: [ExternalDevice.BatteryPart] = []
        for (key, label) in [
            ("device_batteryLevelLeft", "L"),
            ("device_batteryLevelRight", "R"),
            ("device_batteryLevelCase", T("盒"))
        ] {
            if let value = props[key] as? String,
               let level = Int(value.replacingOccurrences(of: "%", with: "")) {
                parts.append(.init(label: label, level: level))
            }
        }
        // 主电量缺失时用左右耳的平均值
        if battery == nil, !parts.isEmpty {
            battery = parts.reduce(0) { $0 + $1.level } / parts.count
        }

        var details: [String] = []
        if parts.isEmpty {
            if let vendorName = vendorName(vendor) {
                details.append(vendorName)
            }
            if let rssi = props["device_rssi"] as? String, let value = Int(rssi) {
                details.append(TF("信号 %d dBm", value))
            }
        }

        var model: String?
        switch kind {
        case .iPhone: model = models["iPhone"]
        case .iPad: model = models["iPad"]
        case .watch: model = models["Watch"]
        default: model = models[name]
        }
        if model == nil {
            model = appleModelName(name: name, kind: kind, isApple: isApple)
        }

        return ExternalDevice(
            id: "bt-\(name)",
            name: name,
            kind: kind,
            isApple: isApple,
            connection: online ? T("蓝牙") : T("已配对"),
            model: model,
            detail: details.isEmpty ? nil : details.joined(separator: " · "),
            battery: battery,
            batteryParts: parts,
            online: online
        )
    }

    /// 名字本身就是 Apple 产品名时，直接当成型号展示（用户改过名的就用分类兜底）
    private nonisolated static func appleModelName(
        name: String,
        kind: ExternalDevice.Kind,
        isApple: Bool
    ) -> String? {
        let lower = name.lowercased()
        if lower.contains("airpods") || lower.contains("beats") { return name }
        if lower.contains("iphone") { return T("iPhone") }
        if lower.contains("ipad") { return T("iPad") }
        if lower.contains("watch") { return "Apple Watch" }
        if isApple {
            switch kind {
            case .keyboard, .mouse, .trackpad: return T("Apple 配件")
            case .airPods, .headphones: return T("AirPods 系列")
            default: return nil
            }
        }
        return nil
    }

    /// 只列常见的几家，够用来在列表里认设备
    private nonisolated static func vendorName(_ raw: String) -> String? {
        let upper = raw.uppercased()
        if upper.contains("0X046D") { return "Logitech" }
        if upper.contains("0X05AC") || upper.contains("APPLE") { return "Apple" }
        if upper.contains("0X0B05") { return "ASUS" }
        if upper.contains("0X04F2") { return "Chicony" }
        if upper.contains("0X1532") { return "Razer" }
        if upper.contains("0X05E3") { return "Genesys" }
        return nil
    }

    // MARK: - iPhone / iPad 型号

    /// devicectl 会把型号写全（iPhone 16 / iPad Air 11-inch），但启动一次要 1~2 秒，
    /// 所以只在真的插着设备时才跑，失败就算了
    private nonisolated static let modelCache = ModelCache()

    /// devicectl 启动一次要 1~2 秒，5 分钟内复用结果
    final class ModelCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: String] = [:]
        private var stamp: Date = .distantPast

        func get() -> [String: String]? {
            lock.lock(); defer { lock.unlock() }
            guard Date().timeIntervalSince(stamp) < 300 else { return nil }
            return value
        }

        func set(_ models: [String: String]) {
            lock.lock(); defer { lock.unlock() }
            value = models
            stamp = Date()
        }
    }

    private nonisolated static func devicectlModels() -> [String: String] {
        if let cached = modelCache.get() { return cached }
        let xcrun = "/usr/bin/xcrun"
        guard FileManager.default.isExecutableFile(atPath: xcrun) else { return [:] }
        guard let data = run(xcrun, ["devicectl", "list", "devices"], timeout: 9),
              let text = String(data: data, encoding: .utf8) else { return [:] }

        // 型号列形如「iPhone 16 (iPhone17,3)」；模拟器那几行不是真机，跳过
        let regex = try? NSRegularExpression(pattern: "(iPhone|iPad)[^()\\n]*\\((?:iPhone|iPad)[0-9,]+\\)")
        var models: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let raw = String(line)
            guard raw.contains("physical"), !raw.contains("simulated") else { continue }
            guard let regex,
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let range = Range(match.range, in: raw) else { continue }
            let full = String(raw[range])
            let model = full.replacingOccurrences(of: " \\((?:iPhone|iPad)[0-9,]+\\)", with: "", options: .regularExpression)
            if model.hasPrefix("iPhone") { models["iPhone"] = model }
            else if model.hasPrefix("iPad") { models["iPad"] = model }
        }
        modelCache.set(models)
        return models
    }

    // MARK: - USB

    private nonisolated static func usbDevices(excluding names: Set<String>) -> [ExternalDevice] {
        guard let data = run("/usr/sbin/system_profiler", ["-json", "SPUSBDataType"]),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPUSBDataType"] as? [[String: Any]] else { return [] }

        var devices: [ExternalDevice] = []
        func walk(_ node: [String: Any]) {
            let name = (node["_name"] as? String) ?? ""
            let lower = name.lowercased()
            let skip = lower.contains("host controller")
                || lower.contains("usb bus")
                || lower.contains("usb3.1 bus")
                || lower.contains("usb31bus")
                || lower.contains("hub")
                || lower.isEmpty

            if !skip, node["vendor_id"] != nil || node["manufacturer"] != nil {
                if !names.contains(name) {
                    let vendor = (node["manufacturer"] as? String) ?? ""
                    let product = (node["product_id"] as? String) ?? ""
                    let vendorID = (node["vendor_id"] as? String) ?? ""
                    var details: [String] = []
                    if !vendorID.isEmpty { details.append(vendorID) }
                    if !product.isEmpty { details.append(product) }
                    if let serial = node["serial_num"] as? String, serial.count >= 4 {
                        details.append(TF("序列号 …%@", String(serial.suffix(4))))
                    }
                    let kind: ExternalDevice.Kind = lower.contains("iphone")
                        ? .iPhone
                        : (lower.contains("ipad") ? .iPad : .usb)
                    devices.append(
                        ExternalDevice(
                            id: "usb-\(name)-\(vendorID)",
                            name: name,
                            kind: kind,
                            isApple: vendor.contains("Apple"),
                            connection: "USB",
                            model: vendor.isEmpty ? nil : vendor,
                            detail: details.isEmpty ? nil : details.joined(separator: " · ")
                        )
                    )
                }
            }

            if let children = node["_items"] as? [[String: Any]] {
                for child in children { walk(child) }
            }
        }
        for item in items { walk(item) }
        return devices
    }

    // MARK: - 外接存储

    private nonisolated static func externalVolumes() -> [ExternalDevice] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsInternalKey,
            .volumeIsBrowsableKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        var devices: [ExternalDevice] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let isInternal = values.volumeIsInternal, !isInternal,
                  values.volumeIsBrowsable ?? false else { continue }
            let total = UInt64(max(values.volumeTotalCapacity ?? 0, 0))
            guard total > 0 else { continue }
            let free = UInt64(max(values.volumeAvailableCapacityForImportantUsage ?? 0, 0))
            devices.append(
                ExternalDevice(
                    id: "vol-\(url.path)",
                    name: values.volumeName ?? url.lastPathComponent,
                    kind: .storage,
                    isApple: false,
                    connection: T("外接"),
                    model: url.path,
                    battery: nil,
                    storageTotal: total,
                    storageUsed: total > free ? total - free : 0
                )
            )
        }
        return devices
    }

    // MARK: - 子进程

    private nonisolated static func run(
        _ path: String,
        _ arguments: [String],
        timeout: TimeInterval = 12
    ) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let collected = NSMutableData()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); collected.append(chunk); lock.unlock()
        }

        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 1)
            pipe.fileHandleForReading.readabilityHandler = nil
            lock.lock(); let snapshot = collected.copy() as? Data; lock.unlock()
            return snapshot
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let result = collected.copy() as? Data; lock.unlock()
        return result
    }
}
