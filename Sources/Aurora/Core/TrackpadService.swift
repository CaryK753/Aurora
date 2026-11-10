import AppKit
import Combine
import IOKit
import IOKit.hid

@MainActor
final class TrackpadService: ObservableObject {
    @Published private(set) var hasHardware = false
    @Published private(set) var deviceName = ""
    @Published private(set) var choices: [String: Int] = [:]
    @Published private(set) var trackingSpeed: Double = 1
    @Published private(set) var isApplying = false
    @Published private(set) var message: String?
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    deinit { timer?.invalidate() }

    static func detectedHardware() -> (Bool, String) {
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if battery != 0 {
            IOObjectRelease(battery)
            return (true, "MacBook 内建触控板")
        }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        for device in devices {
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
            let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
            if vendor == 0x05ac && name.localizedCaseInsensitiveContains("trackpad") { return (true, name) }
        }
        return (false, "未检测到内建触控板或妙控板")
    }

    func refresh() {
        guard !isApplying else { return }
        (hasHardware, deviceName) = Self.detectedHardware()
        for domain in [TrackpadOption.internalDomain, TrackpadOption.externalDomain, TrackpadOption.global, TrackpadOption.dock] {
            let app = domain == TrackpadOption.global ? kCFPreferencesAnyApplication : domain as CFString
            CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        for option in TrackpadOption.all {
            let domain = deviceName.contains("MacBook") || option.domain != TrackpadOption.internalDomain
                ? option.domain : TrackpadOption.externalDomain
            let value = Self.read(domain, option.key)?.intValue ?? option.defaultValue
            var index = option.values.firstIndex(of: value) ?? 0
            if ["spaces", "mission", "expose"].contains(option.id) {
                let key = option.id == "spaces" ? "TrackpadThreeFingerHorizSwipeGesture" : "TrackpadThreeFingerVertSwipeGesture"
                if Self.read(domain, key)?.intValue == 2 { index = 1 }
                else if value == 2 { index = 2 }
            }
            if option.id == "lookup", Self.read(TrackpadOption.internalDomain, "TrackpadThreeFingerTapGesture")?.intValue == 2 { index = 2 }
            if let dockKey = option.dockKey, Self.read(TrackpadOption.dock, dockKey)?.boolValue == false { index = 0 }
            choices[option.id] = index
        }
        trackingSpeed = Self.read(TrackpadOption.global, "com.apple.trackpad.scaling")?.doubleValue ?? 1
    }

    static func read(_ domain: String, _ key: String) -> NSNumber? {
        let app = domain == TrackpadOption.global ? kCFPreferencesAnyApplication : domain as CFString
        return CFPreferencesCopyValue(key as CFString, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber
    }

    func set(_ option: TrackpadOption, choice: Int) {
        guard hasHardware, !isApplying, option.choices.indices.contains(choice) else { return }
        if ["spaces", "mission", "expose"].contains(option.id), choice == 1,
           choices["drag"] == 1 {
            message = T("三指拖移已开启，请先关闭三指拖移或选择四指手势")
            return
        }
        apply(option.writes(choice: choice))
    }

    func setTrackingSpeed(_ value: Double) {
        guard value.isFinite else { return }
        apply([.init(domain: TrackpadOption.global, key: "com.apple.trackpad.scaling", host: false,
                     value: Int(min(max(value, 0), 3) * 1000))], speed: true)
    }

    private func apply(_ writes: [TrackpadOption.Write], speed: Bool = false) {
        guard hasHardware, !isApplying else { return }
        var success = true
        for write in writes {
            let app = write.domain == TrackpadOption.global ? kCFPreferencesAnyApplication : write.domain as CFString
            let host = write.host ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
            let value = speed ? NSNumber(value: Double(write.value) / 1000) : NSNumber(value: write.value)
            CFPreferencesSetValue(write.key as CFString, value, app, kCFPreferencesCurrentUser, host)
            success = CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, host) && success
            let saved = CFPreferencesCopyValue(write.key as CFString, app, kCFPreferencesCurrentUser, host) as? NSNumber
            success = saved == value && success
        }
        guard success else { message = T("系统设置保存失败，请在系统设置中调整"); refresh(); return }
        isApplying = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        process.arguments = ["-u"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in
                self?.isApplying = false
                self?.message = status == 0 ? T("已保存并请求系统应用；部分选项可能需要重新登录") : T("已保存，请重新登录或在系统设置中确认生效")
                self?.refresh()
            }
        }
        do { try process.run() }
        catch { isApplying = false; message = T("已保存，请重新登录或在系统设置中确认生效"); refresh() }
    }

    func openSettings(accessibility: Bool = false) {
        let target = accessibility ? "com.apple.Accessibility-Settings.extension?PointerControl" : "com.apple.Trackpad-Settings.extension"
        if let url = URL(string: "x-apple.systempreferences:\(target)") { NSWorkspace.shared.open(url) }
    }
}
