import Foundation

extension AppState {
    /// 同时重置已运行的服务，避免仅删除偏好后旧状态继续接管系统。
    func resetSettings() {
        settings.resetAll()
        settings.setModule(.trackpad, enabled: trackpad.hasHardware, userInitiated: false)
        pointer.reset()
        logitech.reset()
        display.setRestoreOnLaunch(false)
        display.smoothTransition = true
        clipboard.resetSettings()
        keyboard.stopCleaning(reason: "reset")
        energy.stop()
        energy.activateOnLaunch = false
        energy.keepDisplayOn = false
        energy.autoStopOnLowBattery = true
        appAudio.resetAll()
    }
}
