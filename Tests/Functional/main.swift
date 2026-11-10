import AppKit
import CoreAudio

// 独立验证服务，避免启动菜单栏应用或注册 Finder 扩展。
func T(_ text: String) -> String { text }
func TF(_ text: String, _ argument: String) -> String { String(format: text, argument) }
enum Fmt {
    static func percent(_ value: Double) -> String { "\(Int(value * 100))%" }
}

MainActor.assumeIsolated {
    let energy = EnergyService()
    // 使用默认开启的保护策略；不写入用户偏好。
    if energy.autoStopOnLowBattery {
        energy.enforceBattery(level: 0.1, pluggedIn: false)
        energy.set(.min15)
        precondition(!energy.isActive && energy.duration == .off && energy.endsAt == nil)
        print("✓ 低电量下开启保持唤醒立即停止，并清理倒计时")
        energy.enforceBattery(level: 0.1, pluggedIn: true)
        energy.set(.min15)
        defer { energy.stop() }
        precondition(energy.isActive && energy.endsAt != nil)
        print("✓ 低电量插电时允许保持唤醒")
        energy.enforceBattery(level: 0.1, pluggedIn: false)
        precondition(!energy.isActive)
        print("✓ 拔电后低电量保护停止断言")
    } else {
        print("低电量保护被用户关闭，保留偏好，跳过相应检查")
    }
    let audio = AudioService()
    for input in audio.inputs {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(input.id, &address, 0, nil, &size, &value) == noErr {
            precondition(abs(input.volume - Double(value)) < 0.0001)
        }
    }
    print("✓ 音频输入通道读取一致（\(audio.inputs.count) 个设备）")
    let display = DisplayService()
    let invalid = DisplayModeOption(id: "invalid", width: 0, height: 0, refresh: 0, isCurrent: false)
    for item in display.displays {
        precondition(!display.apply(mode: invalid, for: item.id))
    }
    print("✓ 无效显示模式返回失败，未提交配置")
}
