//  DisplayService.swift
//  Aurora — 显示器控制
//
//  亮度：内建屏走 DisplayServices，外接屏走 DDC/CI（量程、最小/最大覆盖、反向、曲线都可调）
//  软件调光：硬件到底后继续压 gamma，能暗到全黑（复刻 MonitorControl 的 combined brightness）
//  另外还有：16 格方块 OSD、原生亮度键接管、按鼠标所在屏调节、多屏同步、DDC 音量/静音

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
    /// 展示用名称（可能被用户改过）
    var name: String
    /// 系统原始名称
    var nativeName: String
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
    /// 当前 gamma 压暗程度，1 = 没有软件调光
    var softwareBrightness: Double = 1
    /// 亮度是否走软件通道（DDC 不可用 / 强制软件调光）
    var softwareOnly: Bool = false
    /// 读到的 DDC 最大亮度值，用于高级设置里的量程提示
    var ddcMax: Int?
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
            && lhs.softwareBrightness == rhs.softwareBrightness
            && lhs.softwareOnly == rhs.softwareOnly
    }
}

/// 多屏亮度联动方式
enum BrightnessLink: String, CaseIterable, Identifiable {
    case off
    case same
    case offset
    case ratio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return T("关闭")
        case .same: return T("同步数值")
        case .offset: return T("保持差值")
        case .ratio: return T("按比例")
        }
    }

    var detail: String {
        switch self {
        case .off: return T("每块屏幕各调各的")
        case .same: return T("所有屏幕亮度数值一致")
        case .offset: return T("保持屏幕之间的亮度差，一起上下移动")
        case .ratio: return T("外接屏按同样的比例跟随内屏")
        }
    }
}

/// DDC 通道缓存，供后台队列安全访问
final class DDCManager: @unchecked Sendable {
    private var channels: [CGDirectDisplayID: DDCChannel] = [:]
    private var lastAttempt = Date.distantPast
    private let lock = NSLock()

    func channel(for id: CGDirectDisplayID) -> DDCChannel? {
        lock.lock()
        defer { lock.unlock() }
        if let existing = channels[id] { return existing }
        // 第一次找不到就每 20 秒再试一次：显示器休眠后唤醒、中途插上都靠这个自动恢复
        if Date().timeIntervalSince(lastAttempt) > 20 {
            lastAttempt = Date()
            for (display, channel) in DDCChannels.discover() where channels[display] == nil {
                channels[display] = channel
            }
        }
        return channels[id]
    }

    func forget(_ id: CGDirectDisplayID) {
        lock.lock()
        channels[id] = nil
        lock.unlock()
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

    /// 键盘调节时跟随鼠标所在显示器（MonitorControl 的 multiKeyboardBrightness = mouse）
    @Published var followMouse: Bool = DisplayService.bool("display.followMouse", default: true) {
        didSet { UserDefaults.standard.set(followMouse, forKey: "display.followMouse") }
    }
    /// 多屏亮度联动：关闭 / 同步数值 / 保持差值 / 按比例
    @Published var linkMode: BrightnessLink = {
        if let raw = UserDefaults.standard.string(forKey: "display.link"),
           let mode = BrightnessLink(rawValue: raw) { return mode }
        // 老版本只有「同步」开关，迁移过来
        return UserDefaults.standard.bool(forKey: "display.syncBrightness") ? .same : .off
    }() {
        didSet { UserDefaults.standard.set(linkMode.rawValue, forKey: "display.link") }
    }

    /// 旧接口：等价于「同步数值」，导入与重置仍在用
    var syncBrightness: Bool {
        get { linkMode == .same }
        set { linkMode = newValue ? .same : .off }
    }

    /// 联动写入时避免回环
    private var isLinking = false
    /// 调亮度时显示方块 OSD
    @Published var showOSD: Bool = DisplayService.bool("display.osd", default: true) {
        didSet { UserDefaults.standard.set(showOSD, forKey: "display.osd") }
    }
    /// 接管键盘原生亮度键（F1 / F2）
    @Published var useNativeKeys: Bool = DisplayService.bool("display.nativeKeys", default: true) {
        didSet {
            UserDefaults.standard.set(useNativeKeys, forKey: "display.nativeKeys")
            if useNativeKeys { startMediaKeys() } else { stopMediaKeys() }
        }
    }
    /// 硬件到底后用 gamma 继续压暗
    @Published var combinedDimming: Bool = DisplayService.bool("display.combined", default: false) {
        didSet { UserDefaults.standard.set(combinedDimming, forKey: "display.combined") }
    }
    /// 软件调光介入点：低于这个亮度开始压 gamma
    @Published var switchingPoint: Double = {
        let stored = UserDefaults.standard.object(forKey: "display.switchingPoint") as? Double
        return min(max(stored ?? 0.3, 0.05), 0.9)
    }() {
        didSet { UserDefaults.standard.set(switchingPoint, forKey: "display.switchingPoint") }
    }
    /// 原生亮度键拦截是否真的生效（需要辅助功能权限）
    @Published private(set) var nativeKeysActive = false

    let tunings = DisplayTuningStore()
    let gamma = DisplayGamma()
    private let writer = DDCWriter()

    private var fadeTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var mutedVolumes: [CGDirectDisplayID: Double] = [:]

    private let ddc = DDCManager()
    private let readQueue = DispatchQueue(label: "aurora.display.ddc", qos: .userInitiated)
    private var pollingTimer: Timer?
    /// 读到的 DDC 量程（显示器报告的最大值）
    private var ddcMaxima: [CGDirectDisplayID: [String: Int]] = [:]

    let mediaKeys = DisplayMediaKeys()

    init() {
        refresh()
        if restoreOnLaunch { applySavedBrightness() }
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh(preserve: true) }
        }
        if useNativeKeys { startMediaKeys() }
    }

    deinit {
        pollingTimer?.invalidate()
    }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? value
    }

    // MARK: - 读取

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
            let nativeName = screen?.localizedName ?? (isBuiltIn ? T("内建显示器") : T("外接显示器"))
            let tuning = tunings.tuning(for: id)
            let name = tuning.customName.isEmpty ? nativeName : tuning.customName
            let mode = CGDisplayCopyDisplayMode(id)
            let pixelW = mode?.pixelWidth ?? CGDisplayPixelsWide(id)
            let pixelH = mode?.pixelHeight ?? CGDisplayPixelsHigh(id)
            let pointSize = screen?.frame.size ?? CGSize(width: pixelW / 2, height: pixelH / 2)
            let previous = displays.first { $0.id == id }

            var item = DisplayItem(
                id: id,
                name: name,
                nativeName: nativeName,
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

            if isBuiltIn, let value = DisplayServicesShim.brightness(of: id) {
                item.hasBrightness = true
                if fadeTasks[id] == nil { item.brightness = Double(value) }
            }
            item.softwareBrightness = Double(gamma.level(for: id))
            item.softwareOnly = tuning.softwareOnly || (!isBuiltIn && !item.hasBrightness)
            // DDC 不可用的外接屏（HDMI / 扩展坞）也能用 gamma 调光：开了强制软件调光就给滑杆
            if !isBuiltIn && tuning.softwareOnly { item.hasBrightness = true }
            item.ddcMax = ddcMaxima[id]?[DisplayChannel.brightness.rawValue]

            item.modes = loadModes(for: id)
            gamma.capture(id)
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

        readQueue.async { [weak self] in
            var results: [CGDirectDisplayID: (brightness: (Double, Int)?, volume: (Double, Int)?, contrast: (Double, Int)?)] = [:]
            for id in externalIDs {
                guard let channel = ddc.channel(for: id) else { continue }
                func normalized(_ vcp: UInt8) -> (Double, Int)? {
                    guard let reply = channel.read(vcp), reply.max > 0 else { return nil }
                    return (Double(reply.current) / Double(reply.max), Int(reply.max))
                }
                let brightness = normalized(0x10)
                let volume = normalized(0x62)
                let contrast = normalized(0x12)
                if brightness != nil || volume != nil || contrast != nil {
                    results[id] = (brightness, volume, contrast)
                }
            }
            guard !results.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                for (id, value) in results {
                    guard let index = self.displays.firstIndex(where: { $0.id == id }) else { continue }
                    // 正在调光时不要用 DDC 读回值覆盖（读取有延迟，会把滑杆拽回去）
                    if let brightness = value.brightness, self.fadeTasks[id] == nil {
                        self.displays[index].brightness = brightness.0
                        self.displays[index].hasBrightness = true
                        // 首轮 refresh 时还没读到 DDC，softwareOnly 会被判成 true；
                        // 读到通道后要立刻纠正，否则界面会一直显示「软件 · Gamma」
                        self.displays[index].softwareOnly = self.tunings.tuning(for: id).softwareOnly
                        self.displays[index].ddcMax = brightness.1
                        self.ddcMaxima[id, default: [:]][DisplayChannel.brightness.rawValue] = brightness.1
                    }
                    if let volume = value.volume {
                        self.displays[index].volume = volume.0
                        self.displays[index].hasVolume = true
                        self.ddcMaxima[id, default: [:]][DisplayChannel.volume.rawValue] = volume.1
                    }
                    if let contrast = value.contrast {
                        self.displays[index].contrast = contrast.0
                        self.displays[index].hasContrast = true
                        self.ddcMaxima[id, default: [:]][DisplayChannel.contrast.rawValue] = contrast.1
                    }
                }
            }
        }
    }

    // MARK: - 写入

    func setBrightness(_ value: Double, for id: CGDirectDisplayID, animated: Bool = false) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(value, 0), 1)
        let start = displays[index].brightness
        displays[index].brightness = clamped
        saveBrightness(clamped, for: id)

        fadeTasks[id]?.cancel()
        fadeTasks[id] = nil

        guard animated, smoothTransition else {
            applyBrightness(clamped, for: id)
            propagate(from: id, start: start, end: clamped)
            return
        }

        fadeTasks[id] = Task { @MainActor [weak self] in
            let steps = 12
            for step in 1...steps {
                if Task.isCancelled { return }
                let t = Double(step) / Double(steps)
                // easeOutCubic：起步快、收尾稳，观感最接近系统亮度键
                let eased = 1 - pow(1 - t, 3)
                self?.applyBrightness(start + (clamped - start) * eased, for: id)
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            self?.fadeTasks[id] = nil
            // 等本屏淡完再带其它屏，避免一边淡入一边跳变
            self?.propagate(from: id, start: start, end: clamped)
        }
    }

    /// 把这次变化按联动方式带给其它屏（MonitorControl 的 enableBrightnessSync 是「差值」，
    /// 这里多给一个「按比例」——更符合内屏和外屏亮度基准不同的实际观感）
    private func propagate(from id: CGDirectDisplayID, start: Double, end: Double) {
        guard linkMode != .off, !isLinking else { return }
        let delta = end - start
        guard abs(delta) > 0.002 else { return }

        let others = displays.filter { $0.id != id && $0.hasBrightness }
        guard !others.isEmpty else { return }

        // 从 0 起步时比例没有意义，退回「同步数值」
        let ratio = start > 0.02 ? end / start : end
        isLinking = true
        for other in others {
            let target: Double
            switch linkMode {
            case .off: continue
            case .same: target = end
            case .offset: target = other.brightness + delta
            case .ratio: target = start > 0.02 ? other.brightness * ratio : end
            }
            let clamped = min(max(target, 0), 1)
            guard abs(clamped - other.brightness) > 0.0005 else { continue }
            guard let index = displays.firstIndex(where: { $0.id == other.id }) else { continue }
            displays[index].brightness = clamped
            saveBrightness(clamped, for: other.id)
            applyBrightness(clamped, for: other.id)
        }
        isLinking = false
    }

    /// 把 0...1 的「逻辑亮度」拆成硬件 + 软件两段后真正落地
    private func applyBrightness(_ value: Double, for id: CGDirectDisplayID) {
        guard let item = displays.first(where: { $0.id == id }) else { return }
        let tuning = tunings.tuning(for: id)
        let hardwareValue = combinedDimming ? max((value - switchingPoint) / max(1 - switchingPoint, 0.01), 0) : value
        let softwareValue = combinedDimming ? (value < switchingPoint ? value / max(switchingPoint, 0.01) : 1) : 1

        if item.isBuiltIn && !tuning.softwareOnly {
            DisplayServicesShim.setBrightness(Float(hardwareValue), of: id)
            applySoftwareDimming(softwareValue, for: id, avoidGamma: tuning.avoidGamma)
            return
        }

        // 外接屏：能走 DDC 就走硬件，DDC 不可用或强制软件模式时纯 gamma
        if !tuning.softwareOnly, ddc.channel(for: id) != nil, item.hasBrightness {
            writeDDC(id, channel: .brightness, value: hardwareValue)
            applySoftwareDimming(softwareValue, for: id, avoidGamma: tuning.avoidGamma)
        } else {
            applySoftwareDimming(value, for: id, avoidGamma: tuning.avoidGamma)
        }
    }

    private func applySoftwareDimming(_ level: Double, for id: CGDirectDisplayID, avoidGamma: Bool) {
        guard !avoidGamma else {
            // 与其它改 gamma 的 App 冲突时不动 gamma 表，退回纯硬件（避免画面被抢来抢去）
            gamma.reset(id)
            return
        }
        gamma.capture(id)
        gamma.apply(Float(level), to: id)
        if let index = displays.firstIndex(where: { $0.id == id }) {
            displays[index].softwareBrightness = level
        }
    }

    /// 给快捷键 / 原生亮度键用：按 1/16 或 1% 步进
    @discardableResult
    func stepBrightness(up: Bool, fine: Bool = false) -> Bool {
        let targets = keyboardTargets()
        guard !targets.isEmpty else { return false }
        let step = fine ? 0.01 : 0.0625
        for id in targets {
            guard let current = displays.first(where: { $0.id == id })?.brightness else { continue }
            let raw = min(max(current + (up ? step : -step), 0), 1)
            // 普通步进吸附到 1/16，和系统亮度键的手感一致
            let snapped = fine ? (raw * 100).rounded() / 100 : (raw * 16).rounded() / 16
            setBrightness(snapped, for: id)
        }
        if showOSD, let first = targets.first,
           let value = displays.first(where: { $0.id == first })?.brightness {
            let tuning = tunings.tuning(for: first)
            if !tuning.hideOSD {
                DisplayOSD.shared.show(channel: .brightness, value: value, on: screen(for: first))
            }
        }
        return true
    }

    /// 当前该被键盘调节的显示器
    func keyboardTargets() -> [CGDirectDisplayID] {
        let candidates = displays.filter { $0.hasBrightness && tunings.tuning(for: $0.id).keyboardEnabled }
        guard !candidates.isEmpty else { return [] }
        // 联动时只调一块屏，其余让 propagate 带过去
        if linkMode != .off {
            if followMouse, let hovered = displayUnderMouse(), candidates.contains(where: { $0.id == hovered }) {
                return [hovered]
            }
            if let main = candidates.first(where: { $0.isMain }) { return [main.id] }
            return [candidates[0].id]
        }
        if followMouse, let hovered = displayUnderMouse(), candidates.contains(where: { $0.id == hovered }) {
            return [hovered]
        }
        let main = candidates.first(where: \.isMain) ?? candidates[0]
        return [main.id]
    }

    private func displayUnderMouse() -> CGDirectDisplayID? {
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }) else { return nil }
        return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    func setVolume(_ value: Double, for id: CGDirectDisplayID, withOSD: Bool = false) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(value, 0), 1)
        displays[index].volume = clamped
        let tuning = tunings.tuning(for: id)
        if clamped > 0.001 { mutedVolumes[id] = nil }
        if !tuning.softwareOnly {
            writeDDC(id, channel: .volume, value: clamped)
            if tuning.muteAtZero, let channel = ddc.channel(for: id) {
                writer.submit(key: "\(id)-mute", channel: channel, codes: [0x8D], value: clamped <= 0.001 ? 1 : 2)
            }
        }
        if withOSD, showOSD, !tuning.hideOSD {
            DisplayOSD.shared.show(channel: .volume, value: clamped, muted: clamped <= 0.001, on: screen(for: id))
        }
    }

    func toggleMute(for id: CGDirectDisplayID) {
        guard let item = displays.first(where: { $0.id == id }) else { return }
        if item.volume > 0.001 {
            mutedVolumes[id] = item.volume
            setVolume(0, for: id, withOSD: true)
        } else {
            setVolume(mutedVolumes[id] ?? 0.3, for: id, withOSD: true)
        }
    }

    func setContrast(_ value: Double, for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(value, 0), 1)
        displays[index].contrast = clamped
        writeDDC(id, channel: .contrast, value: clamped)
    }

    // MARK: - DDC 换算与写入

    private func range(_ id: CGDirectDisplayID, _ channel: DisplayChannel) -> (min: Int, max: Int) {
        let tuning = tunings.tuning(for: id)
        let minValue = tuning.min(channel)
        let override = tuning.max(channel)
        if override > 0 { return (minValue, max(minValue + 1, override)) }
        let detected = ddcMaxima[id]?[channel.rawValue] ?? 100
        return (minValue, max(detected, minValue + 1))
    }

    /// 供测试与自检用的换算入口
    func encodedDDCValue(_ value: Double, for id: CGDirectDisplayID, channel: DisplayChannel) -> UInt16 {
        encode(value, for: id, channel: channel)
    }

    /// 归一化值 → DDC 原始值（含反向与曲线），与 MonitorControl 的换算一致
    private func encode(_ value: Double, for id: CGDirectDisplayID, channel: DisplayChannel) -> UInt16 {
        let tuning = tunings.tuning(for: id)
        var normalized = min(max(value, 0), 1)
        if tuning.isInverted(channel) { normalized = 1 - normalized }
        let curve = min(max(tuning.curveValue(channel), 0.2), 3)
        let curved = pow(normalized, curve)
        let bounds = range(id, channel)
        let raw = Double(bounds.min) + (Double(bounds.max) - Double(bounds.min)) * curved
        return UInt16(min(max(raw.rounded(), Double(bounds.min)), Double(bounds.max)))
    }

    private func writeDDC(_ id: CGDirectDisplayID, channel: DisplayChannel, value: Double) {
        let tuning = tunings.tuning(for: id)
        guard !tuning.softwareOnly, let ddcChannel = ddc.channel(for: id) else { return }
        let codes = tuning.remapCodes(channel)
        let payload = encode(value, for: id, channel: channel)
        writer.submit(
            key: "\(id)-\(channel.rawValue)",
            channel: ddcChannel,
            codes: codes.isEmpty ? [channel.vcp] : codes,
            value: payload
        )
    }

    // MARK: - 原生亮度键

    func startMediaKeys() {
        guard useNativeKeys else { return }
        mediaKeys.onStep = { [weak self] up, fine in
            guard let self else { return false }
            // 只有需要外接屏时才拦截；纯内建屏交给系统原生通道
            return self.handleNativeKey(up: up, fine: fine)
        }
        nativeKeysActive = mediaKeys.start()
    }

    func stopMediaKeys() {
        mediaKeys.stop()
        nativeKeysActive = false
    }

    /// 辅助功能权限授予后重试装 tap
    func refreshNativeKeys(accessibility: Bool) {
        guard useNativeKeys, accessibility else {
            stopMediaKeys()
            return
        }
        if !nativeKeysActive { startMediaKeys() }
    }

    private func handleNativeKey(up: Bool, fine: Bool) -> Bool {
        let targets = keyboardTargets()
        guard !targets.isEmpty else { return false }
        // 只有「目标是内建屏且没开软件调光」时让系统自己处理，质感最好
        let needsCustom = targets.contains { id in
            guard let item = displays.first(where: { $0.id == id }) else { return false }
            return !item.isBuiltIn || tunings.tuning(for: id).softwareOnly
        }
        guard needsCustom else { return false }
        return stepBrightness(up: up, fine: fine)
    }

    // MARK: - 调校

    func rename(_ name: String, for id: CGDirectDisplayID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tunings.update(id) { $0.customName = trimmed }
        if let index = displays.firstIndex(where: { $0.id == id }) {
            displays[index].name = trimmed.isEmpty ? displays[index].nativeName : trimmed
        }
    }

    func setSoftwareOnly(_ enabled: Bool, for id: CGDirectDisplayID) {
        tunings.update(id) { $0.softwareOnly = enabled }
        if let index = displays.firstIndex(where: { $0.id == id }) {
            displays[index].softwareOnly = enabled
        }
        if enabled {
            // 切到软件调光时先把硬件拉回满亮，否则会「双重变暗」
            if displays.first(where: { $0.id == id })?.isBuiltIn == false {
                writeDDC(id, channel: .brightness, value: 1)
            }
            applySoftwareDimming(displays.first(where: { $0.id == id })?.brightness ?? 1, for: id, avoidGamma: false)
        } else {
            gamma.reset(id)
            setBrightness(displays.first(where: { $0.id == id })?.brightness ?? 1, for: id)
        }
    }

    func resetTuning(for id: CGDirectDisplayID) {
        let name = displays.first(where: { $0.id == id })?.nativeName
        tunings.reset(id)
        gamma.reset(id)
        if let index = displays.firstIndex(where: { $0.id == id }) {
            if let name { displays[index].name = name }
            displays[index].softwareOnly = false
        }
        // 量程改了以后按当前亮度重新落一次，再读回真实值
        if let current = displays.first(where: { $0.id == id })?.brightness {
            applyBrightness(current, for: id)
        }
        refresh(preserve: true)
    }

    // MARK: - 记忆

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

    /// 退出前还原 gamma，别把桌面留在被压暗的状态
    func shutdown() {
        gamma.resetAll()
        stopMediaKeys()
    }

    // MARK: - 模式

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
        gamma.invalidate(id)
        refresh(preserve: true)
        return succeeded
    }
}
