//  HIDDeviceService.swift
//  Aurora — 已连接的输入设备（键盘 / 指针），数据来自 IOKit 的 IOHIDDevice

import AppKit
import Combine
import IOKit

struct HIDDevice: Identifiable, Equatable {
    enum Kind { case keyboard, mouse, trackpad, other }

    let id: String
    var name: String
    var kind: Kind
    var transport: String
    var vendorID: Int
    var productID: Int
    var locationID: Int
    var serial: String
    var isBuiltIn: Bool
    var battery: Int?

    /// 蓝牙 / USB / 内建：设备卡片上只显示这一个短标签
    var transportLabel: String {
        let lower = transport.lowercased()
        if lower.contains("bluetooth") { return T("蓝牙") }
        if lower.contains("usb") { return "USB" }
        if isBuiltIn || lower.contains("fifo") || lower.contains("spi") { return T("内建") }
        return transport.isEmpty ? T("其他") : transport
    }

    var transportSymbol: String {
        let lower = transport.lowercased()
        if lower.contains("bluetooth") { return "dot.radiowaves.left.and.right" }
        if lower.contains("usb") { return "cable.connector" }
        return "laptopcomputer"
    }

    var vendorLabel: String {
        guard vendorID > 0 || productID > 0 else { return "—" }
        return String(format: "%04X:%04X", vendorID, productID)
    }

    /// com.apple.keyboardtype 里的键：ProductID-VendorID-<槽位>
    var keyboardTypeKey: String { "\(productID)-\(vendorID)-0" }

    var canSetType: Bool { vendorID > 0 && productID > 0 }

    var typeLabel: String {
        switch kind {
        case .keyboard: return T("键盘")
        case .mouse: return T("鼠标")
        case .trackpad: return T("触控板")
        case .other: return T("其他")
        }
    }
}

/// 轻量枚举：每 4 秒扫一遍 IOKit，热插拔设备能自动出现
@MainActor
final class HIDDeviceService: ObservableObject {
    @Published private(set) var keyboards: [HIDDevice] = []
    @Published private(set) var pointers: [HIDDevice] = []
    @Published private(set) var lastScan = Date()

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        let devices = Self.enumerate()
        let keyboards = devices.filter { $0.kind == .keyboard }
        let pointers = devices.filter { $0.kind == .mouse }
        if keyboards != self.keyboards { self.keyboards = keyboards }
        if pointers != self.pointers { self.pointers = pointers }
        lastScan = Date()
    }

    // MARK: - IOKit

    private static func enumerate() -> [HIDDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDDevice"),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var seen = Set<String>()
        var devices: [HIDDevice] = []

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }

            guard let props = properties(entry) else { continue }
            let usagePage = number(props["PrimaryUsagePage"])
            let usage = number(props["PrimaryUsage"])
            guard usagePage == 1, usage == 2 || usage == 6 else { continue }

            let product = (props["Product"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = product.isEmpty ? T("未命名设备") : product
            let lower = name.lowercased()
            let builtIn = number(props["Built-In"]) == 1

            var kind: HIDDevice.Kind = usage == 6 ? .keyboard : .mouse
            // 内建键盘 / 触控板会同时提供 usage 2，触控板统一交给「触控板」模块
            if usage == 2, lower.contains("trackpad") || lower.contains("键盘") || lower.contains("keyboard") {
                kind = .trackpad
            }
            guard kind != .trackpad else { continue }

            let vendor = number(props["VendorID"])
            let productID = number(props["ProductID"])
            let location = number(props["LocationID"])
            let serial = props["SerialNumber"] as? String ?? ""
            let id = "\(vendor)-\(productID)-\(location)-\(serial)"
            guard seen.insert(id).inserted else { continue }

            devices.append(HIDDevice(
                id: id,
                name: name,
                kind: kind,
                transport: props["Transport"] as? String ?? "",
                vendorID: vendor,
                productID: productID,
                locationID: location,
                serial: serial,
                isBuiltIn: builtIn,
                battery: battery(for: entry)
            ))
        }

        return devices.sorted {
            if $0.kind != $1.kind { return $0.kind == .keyboard }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func properties(_ entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        return dictionary
    }

    private static func number(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    /// 蓝牙设备的电量挂在父节点上，沿 IOService 平面往上找几层
    private static func battery(for entry: io_registry_entry_t) -> Int? {
        var current: io_registry_entry_t = entry
        IOObjectRetain(current)

        for _ in 0..<5 {
            if let props = properties(current) {
                for key in ["BatteryPercent", "DeviceBatteryPercent", "Battery Level"] {
                    let value = number(props[key])
                    if value > 0, value <= 100 {
                        IOObjectRelease(current)
                        return value
                    }
                }
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                IOObjectRelease(current)
                return nil
            }
            IOObjectRelease(current)
            current = parent
        }
        IOObjectRelease(current)
        return nil
    }
}
