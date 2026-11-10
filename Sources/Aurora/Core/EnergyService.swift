//  EnergyService.swift
//  Aurora — 休眠管理（IOPMAssertion，参考 KeepingYouAwake）

import AppKit
import Combine
import IOKit.pwr_mgt

@MainActor
final class EnergyService: ObservableObject {
    enum Duration: String, CaseIterable, Identifiable {
        case off, min15, min30, hour1, hour2, forever

        var id: String { rawValue }

        var seconds: TimeInterval? {
            switch self {
            case .off: return 0
            case .min15: return 15 * 60
            case .min30: return 30 * 60
            case .hour1: return 60 * 60
            case .hour2: return 2 * 60 * 60
            case .forever: return nil
            }
        }

        var title: String {
            switch self {
            case .off: return T("关闭")
            case .min15: return T("15 分钟")
            case .min30: return T("30 分钟")
            case .hour1: return T("1 小时")
            case .hour2: return T("2 小时")
            case .forever: return T("永不")
            }
        }

        var shortTitle: String {
            switch self {
            case .off: return T("关闭")
            case .min15: return "15m"
            case .min30: return "30m"
            case .hour1: return "1h"
            case .hour2: return "2h"
            case .forever: return "∞"
            }
        }
    }

    @Published private(set) var duration: Duration = .off
    @Published private(set) var endsAt: Date?
    @Published private(set) var remainingText: String = ""
    @Published private(set) var isActive: Bool = false
    /// 电池供电且低于阈值时自动结束，避免「开着保持唤醒把电耗光」
    @Published var autoStopOnLowBattery: Bool = (UserDefaults.standard.object(forKey: "energy.autoStopLowBattery") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(autoStopOnLowBattery, forKey: "energy.autoStopLowBattery")
            checkBattery()
        }
    }

    /// 启动时自动开始保持唤醒（KeepingYouAwake 的 activate on launch）
    @Published var activateOnLaunch: Bool = UserDefaults.standard.bool(forKey: "energy.activateOnLaunch") {
        didSet { UserDefaults.standard.set(activateOnLaunch, forKey: "energy.activateOnLaunch") }
    }

    /// 记住关闭前的节能状态：下次打开 Aurora 自动恢复
    @Published var rememberState: Bool = (UserDefaults.standard.object(forKey: "energy.rememberState") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(rememberState, forKey: "energy.rememberState")
            if !rememberState {
                UserDefaults.standard.removeObject(forKey: "energy.lastDuration")
            }
        }
    }

    /// 自动结束时回调给上层弹提示
    var onAutoStop: ((String) -> Void)?
    /// 启动恢复成功时回调给上层弹提示
    var onRestored: ((Duration) -> Void)?

    @Published var keepDisplayOn: Bool {
        didSet {
            UserDefaults.standard.set(keepDisplayOn, forKey: "energy.keepDisplayOn")
            if isActive { restartAssertion() }
        }
    }

    private var moduleEnabled = true
    private var assertionID: IOPMAssertionID = 0
    private var ticker: Timer?
    private var latestBattery: (level: Double, pluggedIn: Bool)?

    init() {
        keepDisplayOn = UserDefaults.standard.bool(forKey: "energy.keepDisplayOn")
        // 上次退出前保持唤醒还开着的话，稍等模块都就绪后再恢复
        if rememberState,
           let saved = Duration(rawValue: UserDefaults.standard.string(forKey: "energy.lastDuration") ?? ""),
           saved != .off {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.rememberState, self.duration == .off else { return }
                self.set(saved)
                self.onRestored?(saved)
            }
        }
        if activateOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.activateOnLaunch, self.duration == .off else { return }
                self.set(.forever)
            }
        }
    }

    /// 每次电量采样后调用
    func enforceBattery(level: Double, pluggedIn: Bool) {
        latestBattery = (level, pluggedIn)
        checkBattery()
    }

    private func checkBattery() {
        guard let battery = latestBattery, isActive, autoStopOnLowBattery,
              !battery.pluggedIn, battery.level <= 0.2 else { return }
        stop()
        onAutoStop?(TF("电量已低于 %@，已自动结束保持唤醒", Fmt.percent(battery.level)))
    }

    deinit { ticker?.invalidate() }

    func setModuleEnabled(_ enabled: Bool) {
        moduleEnabled = enabled
        if !enabled { stop() }
    }

    func set(_ newValue: Duration) {
        guard moduleEnabled || newValue == .off else { return }
        duration = newValue
        if rememberState {
            UserDefaults.standard.set(newValue.rawValue, forKey: "energy.lastDuration")
        }
        if newValue == .off {
            stop()
        } else {
            if let seconds = newValue.seconds {
                endsAt = Date().addingTimeInterval(seconds)
            } else {
                endsAt = nil
            }
            startAssertion()
            if isActive {
                startTicker()
                checkBattery()
            } else {
                stop()
            }
        }
        updateRemaining()
    }

    func toggle() {
        set(isActive ? .off : .forever)
    }

    private func startAssertion() {
        stopAssertionOnly()
        let reason = "Aurora 保持系统唤醒" as CFString
        let type = keepDisplayOn
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        isActive = result == kIOReturnSuccess && assertionID != 0
        if !isActive { assertionID = 0 }
    }

    private func restartAssertion() {
        guard isActive || duration != .off else { return }
        startAssertion()
    }

    private func stopAssertionOnly() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        isActive = false
    }

    func stop() {
        stopAssertionOnly()
        ticker?.invalidate()
        ticker = nil
        endsAt = nil
        duration = .off
        remainingText = ""
        // 到期 / 低电量 / 手动关闭都算「退出前的状态已变」，不再自动恢复
        if rememberState {
            UserDefaults.standard.set(Duration.off.rawValue, forKey: "energy.lastDuration")
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    private func tick() {
        if let endsAt, Date() >= endsAt {
            stop()
            return
        }
        updateRemaining()
    }

    private func updateRemaining() {
        guard let endsAt else {
            remainingText = isActive ? "∞" : ""
            return
        }
        let seconds = max(0, Int(endsAt.timeIntervalSinceNow))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        remainingText = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
