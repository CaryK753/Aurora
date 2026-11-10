import Foundation

extension ImportService {
    func apply(state: AppState) {
        var applied = 0
        var skipped = 0
        for source in sources {
            for field in source.fields where field.selected {
                if applyField(field, state: state) { applied += 1 } else { skipped += 1 }
            }
        }
        state.pointer.sync()
        let message = TF("已导入 %d 项设置", applied) + (skipped > 0 ? " · \(T("未应用")) \(skipped)" : "")
        setResultMessage(message)
        state.showToast(message, symbol: skipped == 0 ? "arrow.down.circle.fill" : "exclamationmark.triangle")
    }

    private func applyField(_ field: ImportField, state: AppState) -> Bool {
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
        case let (.finderAction(_), .action(action)): state.finderExt.importAction(action)
        case let (.clipboardEnabled, .flag(value)): state.clipboard.setEnabled(value)
        case let (.energyOnLaunch, .flag(value)): state.energy.activateOnLaunch = value
        case let (.energyDisplay, .flag(value)): state.energy.keepDisplayOn = value
        default: return false
        }
        return true
    }
}
