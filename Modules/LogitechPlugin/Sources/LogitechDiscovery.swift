import Foundation
import IOKit.hid

struct LogitechCandidate {
    let device: IOHIDDevice
    let id: String
    let name: String
    let transport: String
    let isReceiver: Bool
}

enum LogitechDiscovery {
    static func candidates() -> [LogitechCandidate] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        var seen = Set<String>()
        return devices.compactMap { device in
            func property(_ name: String) -> Any? { IOHIDDeviceGetProperty(device, name as CFString) }
            guard (property(kIOHIDMaxOutputReportSizeKey) as? NSNumber)?.intValue ?? 0 >= 20 else { return nil }
            let usages = property(kIOHIDDeviceUsagePairsKey) as? [[String: Int]] ?? []
            guard usages.contains(where: { ($0[kIOHIDDeviceUsagePageKey] ?? 0) >= 0xFF00 }) else { return nil }
            let isMouse = usages.contains { $0[kIOHIDDeviceUsagePageKey] == 1 && $0[kIOHIDDeviceUsageKey] == 2 }
            let receiver = (property(kIOHIDProductKey) as? String ?? "").localizedCaseInsensitiveContains("receiver")
                || (property(kIOHIDProductKey) as? String ?? "").localizedCaseInsensitiveContains("bolt")
            guard isMouse || receiver else { return nil }
            let product = property(kIOHIDProductKey) as? String ?? "Logitech"
            let serial = property(kIOHIDSerialNumberKey) as? String ?? ""
            let productID = (property(kIOHIDProductIDKey) as? NSNumber)?.intValue ?? 0
            let location = (property(kIOHIDLocationIDKey) as? NSNumber)?.intValue ?? 0
            let id = "\(productID)-\(serial.isEmpty ? String(location) : serial)"
            guard seen.insert(id).inserted else { return nil }
            return LogitechCandidate(device: device, id: id, name: product,
                transport: property(kIOHIDTransportKey) as? String ?? "HID",
                isReceiver: product.localizedCaseInsensitiveContains("receiver") || product.localizedCaseInsensitiveContains("bolt"))
        }.sorted { $0.name < $1.name }
    }
}
