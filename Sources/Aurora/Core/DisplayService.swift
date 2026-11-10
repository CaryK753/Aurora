//  DisplayService.swift
//  Aurora — 显示器控制：亮度（内置屏 DisplayServices / 外接屏 DDC-CI）、音量、对比度、分辨率

import AppKit
import Combine
import CoreGraphics

struct DisplayModeOption: Identifiable, Hashable {
    let id: String
    let width: Int
    let height: Int
    let refresh: Double
    let isCurrent: Bool
    var label: String { "\(width) × \(height)" }
}

struct DisplayItem: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var name: String
    var isBuiltIn: Bool
    var isMain: Bool
    var pointSize: CGSize
    var pixelSize: CGSize
    var refresh: Double
    var brightness: Double
    var volume: Double
    var contrast: Double
    var hasBrightness: Bool
    var hasVolume: Bool
    var hasContrast: Bool
    var modes: [DisplayModeOption] = []

    var resolutionLabel: String { "\(Int(pointSize.width)) × \(Int(pointSize.height))" }
    var pixelLabel: String { "\(Int(pixelSize.width)) × \(Int(pixelSize.height))" }

    static func == (lhs: DisplayItem, rhs: DisplayItem) -> Bool {
        lhs.id == rhs.id
            && lhs.brightness == rhs.brightness
            && lhs.volume == rhs.volume
            && lhs.contrast == rhs.contrast
            && lhs.modes == rhs.modes
            && lhs.name == rhs.name
    }
}

/// DDC 通道缓存，供后台队列安全访问
final class DDCManager: @unchecked Sendable {
    private var channels: [CGDirectDisplayID: DDCChannel] = [:]
    private let lock = NSLock()

    func channel(for id: CGDirectDisplayID) -> DDCChannel? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = channels[id] { return existing }
        let created = DDCChannel.make(for: id)
        channels[id] = created
        return created
    }
}

@MainActor
final class DisplayService: ObservableObject {
    @Published private(set) var displays: [DisplayItem] = []

    @Published var restoreOnLaunch: Bool = UserDefaults.standard.bool(forKey: "display.restoreOnLaunch")
    /// 亮度切换用 ~0.2s 缓动过渡，避免点预设时「啪」地跳一下
    @Published var smoothTransition: Bool = (UserDefaults.standard.object(forKey: "display.smooth") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(smoothTransition, forKey: "display.smooth") }
    }

    private var fadeTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]

    private let ddc = DDCManager()
    private let queue = DispatchQueue(label: "aurora.display.ddc", qos: .userInitiated)
    private var pollingTimer: Timer?

    init() {
        refresh()
        if restoreOnLaunch { applySavedBrightness() }
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh(preserve: true) }
        }
    }

    deinit {
        pollingTimer?.invalidate()
    }

    func refresh(preserve: Bool = false) {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            displays = []
            return
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return }

        let screens = NSScreen.screens
        var updated: [DisplayItem] = []

        for id in ids.prefix(Int(count)) {
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            let screen = screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            let name = screen?.localizedName ?? (isBuiltIn ? T("内建显示器") : T("外接显示器"))
            let mode = CGDisplayCopyDisplayMode(id)
            let pixelW = mode?.pixelWidth ?? CGDisplayPixelsWide(id)
            let pixelH = mode?.pixelHeight ?? CGDisplayPixelsHigh(id)
            let pointSize = screen?.frame.size ?? CGSize(width: pixelW / 2, height: pixelH / 2)
            let previous = displays.first { $0.id == id }

            var item = DisplayItem(
                id: id,
                name: name,
                isBuiltIn: isBuiltIn,
                isMain: CGDisplayIsMain(id) != 0,
                pointSize: pointSize,
                pixelSize: CGSize(width: pixelW, height: pixelH),
                refresh: currentRefreshRate(id),
                brightness: previous?.brightness ?? 0.5,
                volume: previous?.volume ?? 0.3,
                contrast: previous?.contrast ?? 0.75,
                hasBrightness: previous?.hasBrightness ?? false,
                hasVolume: previous?.hasVolume ?? false,
                hasContrast: previous?.hasContrast ?? false
            )

            if let value = DisplayServicesShim.brightness(of: id) {
                item.hasBrightness = true
                if fadeTasks[id] == nil { item.brightness = Double(value) }
            }

            item.modes = loadModes(for: id)
            updated.append(item)
        }

        displays = updated
        readDDCInBackground()
    }

    private func currentRefreshRate(_ id: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.refreshRate > 0 else { return 60 }
        return mode.refreshRate
    }

    private func loadModes(for id: CGDirectDisplayID) -> [DisplayModeOption] {
        guard let list = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] else { return [] }
        let current = CGDisplayCopyDisplayMode(id)
        var best: [String: DisplayModeOption] = [:]

        for mode in list {
            guard mode.width >= 800, mode.height >= 600 else { continue }
            // 只保留整数缩放档位
            guard mode.pixelWidth % max(mode.width, 1) == 0 else { continue }
            let key = "\(mode.width)x\(mode.height)"
            let refresh = mode.refreshRate > 0 ? mode.refreshRate : 60
            let isCurrent = current.map {
                $0.width == mode.width && $0.height == mode.height && abs($0.refreshRate - mode.refreshRate) < 0.6
            } ?? false
            if let existing = best[key], existing.refresh >= refresh { continue }
            best[key] = DisplayModeOption(id: key, width: mode.width, height: mode.height, refresh: refresh, isCurrent: isCurrent)
        }

        return best.values.sorted {
            $0.width == $1.width ? $0.height > $1.height : $0.width > $1.width
        }
    }

    // MARK: - DDC 读取

    private func readDDCInBackground() {
        let externalIDs = displays.filter { !$0.isBuiltIn }.map(\.id)
        guard !externalIDs.isEmpty else { return }
        let ddc = self.ddc

        queue.async {
            var results: [CGDirectDisplayID: (brightness: Double?, volume: Double?, contrast: Double?)] = [:]
            for id in externalIDs {
                guard let channel = ddc.channel(for: id) else { continue }
                let brightness = channel.read(0x10).map { Double($0.current) / Double($0.max) }
                let volume = channel.read(0x62).map { Double($0.current) / Double($0.max) }
                let contrast = channel.read(0x12).map { Double($0.current) / Double($0.max) }
                if brightness != nil || volume != nil || contrast != nil {
                    results[id] = (brightness, volume, contrast)
                }
            }
            guard !results.isEmpty else { return }
            Task { @MainActor in
                for (id, value) in results {
                    guard let index = self.displays.firstIndex(where: { $0.id == id }) else { continue }
                    if let brightness = value.brightness {
                        self.displays[index].brightness = brightness
                        self.displays[index].hasBrightness = true
                    }
                    if let volume = value.volume {
                        self.displays[index].volume = volume
                        self.displays[index].hasVolume = true
                    }
                    if let contrast = value.contrast {
                        self.displays[index].contrast = contrast
                        self.displays[index].hasContrast = true
                    }
                }
            }
        }
    }

    // MARK: - 写入

    func setBrightness(_ value: Double, for id: CGDirectDisplayID, animated: Bool = false) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(value, 0), 1)
        displays[index].brightness = clamped
        fadeTasks[id]?.cancel()
        fadeTasks[id] = nil

        guard displays[index].isBuiltIn else {
            saveBrightness(clamped, for: id)
            let ddc = self.ddc
            queue.async { ddc.channel(for: id)?.write(0x10, value: UInt16(clamped * 100)) }
            return
        }

        guard animated, smoothTransition else {
            saveBrightness(clamped, for: id)
            DisplayServicesShim.setBrightness(Float(clamped), of: id)
            return
        }

        let start = Double(DisplayServicesShim.brightness(of: id) ?? Float(clamped))
        saveBrightness(clamped, for: id)
        fadeTasks[id] = Task { @MainActor in
            let steps = 12
            for step in 1...steps {
                if Task.isCancelled { return }
                let t = Double(step) / Double(steps)
                // easeOutCubic：起步快、收尾稳，观感最接近系统亮度键
                let eased = 1 - pow(1 - t, 3)
                DisplayServicesShim.setBrightness(Float(start + (clamped - start) * eased), of: id)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            self.fadeTasks[id] = nil
        }
    }

    /// 给快捷键用：按步长加减主屏亮度
    func adjustBrightness(by delta: Double) {
        guard let display = displays.first(where: { $0.isMain }) ?? displays.first,
              display.hasBrightness else { return }
        setBrightness(display.brightness + delta, for: display.id, animated: true)
    }

    func setVolume(_ value: Double, for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[index].volume = value
        let ddc = self.ddc
        queue.async { ddc.channel(for: id)?.write(0x62, value: UInt16(value * 100)) }
    }

    func setContrast(_ value: Double, for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[index].contrast = value
        let ddc = self.ddc
        queue.async { ddc.channel(for: id)?.write(0x12, value: UInt16(value * 100)) }
    }

    func setRestoreOnLaunch(_ enabled: Bool) {
        restoreOnLaunch = enabled
        UserDefaults.standard.set(enabled, forKey: "display.restoreOnLaunch")
        if enabled { saveAllCurrentBrightness() }
    }

    private func saveBrightness(_ value: Double, for id: CGDirectDisplayID) {
        var stored = UserDefaults.standard.dictionary(forKey: "display.brightness") as? [String: Double] ?? [:]
        stored["\(id)"] = value
        UserDefaults.standard.set(stored, forKey: "display.brightness")
    }

    private func saveAllCurrentBrightness() {
        for display in displays where display.hasBrightness {
            saveBrightness(display.brightness, for: display.id)
        }
    }

    private func applySavedBrightness() {
        guard let stored = UserDefaults.standard.dictionary(forKey: "display.brightness") as? [String: Double] else { return }
        for (key, value) in stored {
            guard let id = CGDirectDisplayID(key) else { continue }
            if CGDisplayIsOnline(id) != 0 {
                setBrightness(value, for: id)
            }
        }
    }

    @discardableResult
    func apply(mode option: DisplayModeOption, for id: CGDirectDisplayID) -> Bool {
        guard let list = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode],
              let target = list.first(where: {
                  let refresh = $0.refreshRate > 0 ? $0.refreshRate : 60
                  return $0.width == option.width && $0.height == option.height
                      && abs(refresh - option.refresh) < 0.6 && $0.isUsableForDesktopGUI()
              }) else { return false }
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success else { return false }
        guard CGConfigureDisplayWithDisplayMode(configuration, id, target, nil) == .success else {
            CGCancelDisplayConfiguration(configuration)
            return false
        }
        let succeeded = CGCompleteDisplayConfiguration(configuration, .permanently) == .success
        refresh(preserve: true)
        return succeeded
    }
}
