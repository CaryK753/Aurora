import CoreGraphics
import Foundation

extension ImportService {
    func apply(state: AppState) {
        var applied = 0
        var skipped = 0
        var touchedDisplays = Set<CGDirectDisplayID>()
        for source in sources {
            for field in source.fields where field.selected {
                if applyField(field, state: state, touchedDisplays: &touchedDisplays) {
                    applied += 1
                } else {
                    skipped += 1
                }
            }
        }
        state.pointer.sync()
        // 量程/曲线改过以后按新换算重新落一次亮度，否则滑杆位置和实际亮度会对不上
        for id in touchedDisplays {
            if let display = state.display.displays.first(where: { $0.id == id }) {
                state.display.setBrightness(display.brightness, for: id)
            }
        }
        if !touchedDisplays.isEmpty { state.display.refresh(preserve: true) }

        let message = TF("已导入 %d 项设置", applied) + (skipped > 0 ? " · \(T("未应用")) \(skipped)" : "")
        setResultMessage(message)
        state.showToast(message, symbol: skipped == 0 ? "arrow.down.circle.fill" : "exclamationmark.triangle")
    }

    private func applyField(_ field: ImportField, state: AppState, touchedDisplays: inout Set<CGDirectDisplayID>) -> Bool {
        switch (field.target, field.value) {
        case let (.invertScroll, .flag(value)): state.pointer.invertScroll = value
        case let (.shiftHorizontal, .flag(value)): state.pointer.shiftToHorizontal = value
        case let (.scrollSpeed, .number(value)):
            guard value.isFinite else { return false }
            state.pointer.scrollSpeed = min(max(value, 0.3), 3)
        case let (.pointerSpeed, .number(value)):
            guard value.isFinite else { return false }
            state.pointer.speed = min(max(value, 0.3), 3)
        case let (.pointerAcceleration, .number(value)):
            guard value.isFinite else { return false }
            state.pointer.acceleration = min(max(value, 0), 1)
        case let (.brightness(id), .number(value)):
            guard value.isFinite, state.display.displays.contains(where: { $0.id == id && $0.hasBrightness }) else { return false }
            state.display.setBrightness(value, for: id)
            touchedDisplays.insert(id)
        case let (.finderAction(_), .action(action)): state.finderExt.importAction(action)
        case let (.clipboardEnabled, .flag(value)): state.clipboard.setEnabled(value)
        case let (.energyOnLaunch, .flag(value)): state.energy.activateOnLaunch = value
        case let (.energyDisplay, .flag(value)): state.energy.keepDisplayOn = value

        // MARK: 显示器（MonitorControl）
        case let (.contrast(id), .number(value)):
            guard value.isFinite, state.display.displays.contains(where: { $0.id == id }) else { return false }
            state.display.setContrast(min(max(value, 0), 1), for: id)
            touchedDisplays.insert(id)
        case let (.displayVolume(id), .number(value)):
            guard value.isFinite, state.display.displays.contains(where: { $0.id == id }) else { return false }
            state.display.setVolume(min(max(value, 0), 1), for: id)
        case let (.displayName(id), .text(name)):
            guard state.display.displays.contains(where: { $0.id == id }) else { return false }
            state.display.rename(name, for: id)
        case let (.ddcMax(id), .integer(value)):
            guard state.display.displays.contains(where: { $0.id == id }), value > 1 else { return false }
            state.display.tunings.update(id) { $0.maxValue[DisplayChannel.brightness.rawValue] = value }
            touchedDisplays.insert(id)
        case let (.ddcMin(id), .integer(value)):
            guard state.display.displays.contains(where: { $0.id == id }) else { return false }
            state.display.tunings.update(id) { $0.minValue[DisplayChannel.brightness.rawValue] = max(value, 0) }
            touchedDisplays.insert(id)
        case let (.ddcCurve(id), .number(value)):
            guard state.display.displays.contains(where: { $0.id == id }), value.isFinite else { return false }
            state.display.tunings.update(id) { $0.curve[DisplayChannel.brightness.rawValue] = min(max(value, 0.2), 3) }
            touchedDisplays.insert(id)
        case let (.ddcInvert(id), .flag(value)):
            guard state.display.displays.contains(where: { $0.id == id }) else { return false }
            state.display.tunings.update(id) { $0.invert[DisplayChannel.brightness.rawValue] = value }
            touchedDisplays.insert(id)
        case let (.displaySoftwareOnly(id), .flag(value)):
            guard state.display.displays.contains(where: { $0.id == id }) else { return false }
            state.display.setSoftwareOnly(value, for: id)
        case let (.displayKeyboardEnabled(id), .flag(value)):
            guard state.display.displays.contains(where: { $0.id == id }) else { return false }
            state.display.tunings.update(id) { $0.keyboardEnabled = value }
        case let (.displayMuteAtZero(id), .flag(value)):
            guard state.display.displays.contains(where: { $0.id == id }) else { return false }
            state.display.tunings.update(id) { $0.muteAtZero = value }
        case let (.displayHideOSD(id), .flag(value)):
            guard state.display.displays.contains(where: { $0.id == id }) else { return false }
            state.display.tunings.update(id) { $0.hideOSD = value }
        case let (.smoothBrightness, .flag(value)):
            state.display.smoothTransition = value
        case let (.combinedDimming, .flag(value)):
            state.display.combinedDimming = value
        case let (.syncDisplays, .flag(value)):
            state.display.syncBrightness = value
        case let (.followMouseDisplay, .flag(value)):
            state.display.followMouse = value
        case let (.restoreBrightness, .flag(value)):
            state.display.setRestoreOnLaunch(value)

        default: return false
        }
        return true
    }
}
