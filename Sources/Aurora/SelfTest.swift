//  SelfTest.swift
//  Aurora — 自检模式：`Aurora --selftest` 逐项验证底层能力是否可用

import AppKit
import AVFoundation
import ApplicationServices
import os
import CoreAudio
import AudioToolbox
import ServiceManagement
import ScreenCaptureKit
import Carbon.HIToolbox

@MainActor
enum SelfTest {
    /// 验证滚轮变换：速度 / 反转 / Shift 横向 / 修饰键反转
    static func scrollTransform() -> Int32 {
        let engine = PointerEngine()
        var failures = 0

        func event(_ dy: Int32, flags: CGEventFlags = []) -> CGEvent {
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0)!
            e.flags = flags
            return e
        }

        func run(_ config: PointerConfig, _ dy: Int32, flags: CGEventFlags = []) -> (Int64, Int64) {
            engine.update(config)
            let e = event(dy, flags: flags)
            _ = engine.process(type: .scrollWheel, event: e)
            return (
                e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            )
        }

        func check(_ name: String, _ condition: Bool, _ detail: String) {
            print(condition ? "✓ \(name)：\(detail)" : "✗ \(name)：\(detail)")
            if !condition { failures += 1 }
        }

        var y = run(PointerConfig(scrollSpeed: 2), 10)
        check("2× 速度", y.0 == 20, "10 → \(y.0)")

        y = run(PointerConfig(invertScroll: true), 10)
        check("反转方向", y.0 == -10, "10 → \(y.0)")

        y = run(PointerConfig(shiftToHorizontal: true), 12, flags: .maskShift)
        check("Shift 横向", y.0 == 0 && y.1 == 12, "纵向 \(y.0) · 横向 \(y.1)")

        y = run(PointerConfig(modifierInvert: .option), 8, flags: .maskAlternate)
        check("⌥ 临时反转", y.0 == -8, "8 → \(y.0)")

        y = run(PointerConfig(modifierInvert: .option), 8, flags: [])
        check("无修饰键不变", y.0 == 8, "8 → \(y.0)")

        // 残差：0.3 倍下连续滚 10 格，总量应仍为 3
        engine.update(PointerConfig(scrollSpeed: 0.3))
        var total: Int64 = 0
        for _ in 0..<10 {
            let e = event(1)
            _ = engine.process(type: .scrollWheel, event: e)
            total += e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        }
        check("残差累积", total == 3, "10×1 @0.3 → \(total)")

        return failures == 0 ? 0 : 1
    }

    /// 端到端验证：关闭一个快速操作 → 读回偏好 → 再打开（会重启访达）
    static func toggleRoundTrip() -> Int32 {
        let service = ContextMenuService()
        guard let item = service.items.first(where: { $0.kind == .quickAction }) else {
            print("✗ 没有可测试的菜单项")
            return 1
        }
        print("测试项：\(item.title) (\(item.id))  初始状态：\(item.isEnabled)")

        service.setEnabled(false, for: item.id)
        Thread.sleep(forTimeInterval: 2.0)
        let afterOff = (CFPreferencesCopyAppValue("FinderActive" as CFString, "pbs" as CFString) as? [String: Bool])?[item.id]
        print("关闭后 pbs 记录：\(String(describing: afterOff))")

        service.setEnabled(true, for: item.id)
        Thread.sleep(forTimeInterval: 2.0)
        let afterOn = (CFPreferencesCopyAppValue("FinderActive" as CFString, "pbs" as CFString) as? [String: Bool])?[item.id]
        print("恢复后 pbs 记录：\(String(describing: afterOn))")

        let ok = afterOff == false && afterOn == true
        print(ok ? "✓ 开关链路正常" : "✗ 开关链路异常")
        return ok ? 0 : 1
    }

    /// 端到端验证：生成一个快速操作 workflow，校验文件合法性后清理
    static func customActionRoundTrip() -> Int32 {
        let service = CustomActionService()
        let before = service.actions.count
        service.draftName = "AuroraTest"
        service.draftCommand = "echo \"$@\" > /tmp/aurora-action-test.txt"
        service.add()
        guard let action = service.actions.last else {
            print("✗ 未创建动作"); return 1
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Services/\(action.fileName)/Contents/document.wflow")
        let exists = FileManager.default.fileExists(atPath: path.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = ["-lint", path.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        print("workflow: \(path.path)")
        print("存在：\(exists) · 校验：\(output.trimmingCharacters(in: .whitespacesAndNewlines))")

        service.remove(action)
        let cleaned = !FileManager.default.fileExists(atPath: path.path)
        print("清理：\(cleaned) · 动作数 \(before) → \(service.actions.count)")
        let ok = exists && output.contains("OK") && cleaned
        print(ok ? "✓ 自定义动作链路正常" : "✗ 自定义动作链路异常")
        return ok ? 0 : 1
    }

    /// 创建并保留一个演示动作，用于人工验证右键菜单是否出现
    static func createDemoAction() -> Int32 {
        let service = CustomActionService()
        service.draftName = "AuroraDemo"
        service.draftCommand = "echo \"$@\" > /tmp/aurora-demo.txt && open -a TextEdit /tmp/aurora-demo.txt"
        service.add()
        guard let action = service.actions.last else { print("✗ 创建失败"); return 1 }
        print("已创建：\(action.fileName)")
        return 0
    }

    /// 登录项开关（用于验证 SMAppService 是否可用）
    static func setLoginItem(_ enabled: Bool) -> Int32 {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                print("登录项状态：\(SMAppService.mainApp.status.rawValue) (2 = 已启用)")
                return 0
            } catch {
                print("失败：\(error.localizedDescription)")
                return 1
            }
        }
        return 1
    }

    /// 验证节能断言：开启 15 分钟 → 检查 pmset → 结束
    static func energyRoundTrip() -> Int32 {
        let service = EnergyService()
        service.set(.min15)
        Thread.sleep(forTimeInterval: 0.8)
        let active = service.isActive

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let listed = output.contains("Aurora") || output.contains("PreventUserIdleSystemSleep")

        service.stop()
        let stopped = !service.isActive
        print("断言创建：\(active) · pmset 可见：\(listed) · 停止：\(stopped)")
        let ok = active && stopped
        print(ok ? "✓ 节能断言链路正常" : "✗ 节能断言异常")
        return ok ? 0 : 1
    }

    /// 端到端验证按应用音量：起一个持续发声的进程 → 建 tap 链路 → 确认有音频流过
    static func audioTapRoundTrip() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-r", "90", "Aurora per application volume routing test one two three four five six seven eight nine ten"]
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        defer { if process.isRunning { process.terminate() } }

        // 等进程注册出音频对象
        var object = AudioObjectID(0)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, object == 0 {
            usleep(200_000)
            object = PerAppAudioService.debugProcessObject(pid: process.processIdentifier)
        }
        guard object != 0 else {
            print("✗ 没拿到进程音频对象")
            return 1
        }

        let chain = AppAudioChain(
            bundleID: "test.say",
            pid: process.processIdentifier,
            processObject: object,
            gain: 0.5
        )
        guard chain.start() else {
            print("✗ 音频链路启动失败")
            return 1
        }
        Thread.sleep(forTimeInterval: 2.0)
        let captured = chain.capturedFrames
        let rendered = chain.renderedFrames
        let peak = chain.peak
        chain.teardown()

        // 服务层：能否把正在发声的进程列出来并接管
        var serviceControlled = false
        var listedName = "—"
        let service = PerAppAudioService()
        service.refresh()
        if let item = service.items.first(where: { $0.name.lowercased().contains("say") }) {
            listedName = item.name
            service.setVolume(0.4, for: item.id)
            Thread.sleep(forTimeInterval: 0.8)
            serviceControlled = service.isControlled(item.id)
            service.setVolume(1.0, for: item.id)
        }
        service.shutdown()
        print("服务层：列表内含 \(listedName) · 接管=\(serviceControlled)")

        print("捕获帧：\(captured) · 回放帧：\(rendered) · 输出峰值：\(String(format: "%.3f", peak))")
        let ok = captured > 20_000 && rendered > 10_000 && peak > 0.01 && serviceControlled
        print(ok ? "✓ 按应用音量链路正常" : "✗ 按应用音量链路异常")
        return ok ? 0 : 1
    }

    /// 验证「接管 → 拆除」之后，原应用的声音是否真的回到原生通路
    /// 用户报的 bug：单独调过某个 App 的音量后，它自己变成 0%（静音且不恢复）
    static func audioMuteLeak() -> Int32 {
        // 默认用「静音音源」：一个只输出 0 采样的播放器进程。
        // 它同样会在 CoreAudio 里注册成发声进程、tap 也能捕获，但喇叭一点声音都没有。
        // AURORA_LOUD_SOURCE=1 时才退回 say（会真的出声）。
        let loud = ProcessInfo.processInfo.environment["AURORA_LOUD_SOURCE"] == "1"
        let process = Process()
        if loud {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            process.arguments = ["-r", "60", """
            Aurora mute leak test, speaking aloud because AURORA_LOUD_SOURCE is set. \
            One two three four five six seven eight nine ten eleven twelve.
            """]
        } else {
            // AURORA_SOURCE=noise 时用 ±1 LSB 的白噪声（约 -90 dBFS）：内容非零，
            // 但人耳完全听不见，用来复现「有真实音频才触发」的那类问题
            let noise = ProcessInfo.processInfo.environment["AURORA_SOURCE"] == "noise"
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            process.arguments = [Self.waveFile(amplitude: noise ? 1 : 0)]
        }
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        defer { if process.isRunning { process.terminate() } }

        var object = AudioObjectID(0)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, object == 0 {
            usleep(200_000)
            object = PerAppAudioService.debugProcessObject(pid: process.processIdentifier)
        }
        guard object != 0 else {
            print("✗ 没拿到进程音频对象（可能需要「系统音频录制」权限）")
            return 1
        }

        let pid = process.processIdentifier
        let volumeBefore = defaultOutputVolume()

        // 后台采样设备音量，定位「什么时候被改」而不是只在结束时对比
        let samplerStop = OSAllocatedUnfairLock(initialState: false)
        let monitor = Thread {
            let start = Date()
            while !samplerStop.withLock({ $0 }) {
                let v = Self.defaultOutputVolume()
                print(String(format: "[vol] +%.2fs %.3f muted=%@", Date().timeIntervalSince(start), v, Self.defaultOutputMuted() ? "YES" : "no"))
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        monitor.start()

        // 1) 旁听（不打断原生通路），记录基线
        func probe(_ label: String) -> (frames: Int, peak: Float) {
            let chain = AppAudioChain(bundleID: "probe.\(label)", pid: pid, processObject: object, gain: 1, mute: false)
            guard chain.start() else {
                print("✗ \(label)：旁听链路起不来")
                return (0, 0)
            }
            Thread.sleep(forTimeInterval: 1.4)
            let result = (chain.capturedFrames, chain.peak)
            chain.teardown()
            print("\(label)：捕获 \(result.0) 帧 · 峰值 \(String(format: "%.3f", result.1))")
            return result
        }

        let baseline = probe("接管前")

        // 循环多轮接管/拆除，观察设备状态在每一轮之间有没有被改坏
        let loops = max(1, Int(ProcessInfo.processInfo.environment["AURORA_LOOPS"] ?? "") ?? 1)
        if loops > 1 {
            samplerStop.withLock { $0 = true }
            Thread.sleep(forTimeInterval: 0.4)
            var drifted = 0
            var previous = (volume: defaultOutputVolume(), muted: defaultOutputMuted())
            for round in 1...loops {
                let chain = AppAudioChain(bundleID: "loop.\(round)", pid: pid, processObject: object, gain: 0.4, mute: true)
                guard chain.start() else { print("✗ 第\(round) 轮接管失败"); return 1 }
                Thread.sleep(forTimeInterval: 1.0)
                chain.teardown()
                Thread.sleep(forTimeInterval: 0.4)
                let now = (volume: defaultOutputVolume(), muted: defaultOutputMuted())
                let ok = abs(now.volume - previous.volume) < 0.02 && now.muted == previous.muted
                if !ok { drifted += 1 }
                print(String(format: "第%d轮：%.3f%@ → %.3f%@ %@", round, previous.volume, previous.muted ? "(静音)" : "",
                             now.volume, now.muted ? "(静音)" : "", ok ? "✓" : "✗ 设备状态被改"))
                previous = now
            }
            print(drifted == 0 ? "✓ \(loops) 轮接管/拆除后设备状态稳定" : "✗ \(drifted)/\(loops) 轮把设备状态改坏了")
            return drifted == 0 ? 0 : 1
        }

        // 2) 真正接管：静音原生通路 + 40% 增益回放（AURORA_SKIP_MUTE=1 时只测旁听）
        if ProcessInfo.processInfo.environment["AURORA_SKIP_MUTE"] == "1" {
            samplerStop.withLock { $0 = true }
            Thread.sleep(forTimeInterval: 0.4)
            print("跳过接管（仅旁听）")
            return baseline.frames > 10_000 ? 0 : 1
        }
        let chain = AppAudioChain(bundleID: "probe.muted", pid: pid, processObject: object, gain: 0.4, mute: true)
        guard chain.start() else {
            print("✗ 接管失败")
            return 1
        }
        Thread.sleep(forTimeInterval: 2.0)
        print("接管中：捕获 \(chain.capturedFrames) 帧 · 回放 \(chain.renderedFrames) 帧 · 峰值 \(String(format: "%.3f", chain.peak))")
        chain.teardown()

        // 3) 拆除后再旁听：声音应该回到原生通路
        Thread.sleep(forTimeInterval: 0.9)
        let recovered = probe("拆除后")
        let volumeAfter = defaultOutputVolume()
        samplerStop.withLock { $0 = true }
        Thread.sleep(forTimeInterval: 0.4)

        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print(ok ? "✓ \(name)：\(detail)" : "✗ \(name)：\(detail)")
            if !ok { failures += 1 }
        }
        if loud {
            check("接管前有声音", baseline.frames > 10_000, "\(baseline.frames) 帧")
            check("拆除后恢复", recovered.frames > baseline.frames / 3, "\(recovered.frames) 帧（基线 \(baseline.frames)）")
        } else {
            // 静音源只用来验证「设备状态有没有被改坏」，不校验帧数
            print("静音音源：捕获 \(baseline.frames) / \(recovered.frames) 帧（仅供参考）")
        }
        check("系统输出音量未被改动", abs(volumeAfter - volumeBefore) < 0.02,
              "\(String(format: "%.2f", volumeBefore)) → \(String(format: "%.2f", volumeAfter))")
        return failures == 0 ? 0 : 1
    }

    /// 生成 60 秒的 WAV（44.1k / 立体声 / 16bit）。amplitude 为每采样点幅度，
    /// 0 是全静音，1 是 ±1 LSB 的极低噪底（听不见，但音频内容非零）。
    private static func waveFile(amplitude: Int16) -> String {
        let path = NSTemporaryDirectory() + "aurora-source-\(amplitude).wav"
        if FileManager.default.fileExists(atPath: path) { return path }
        let sampleRate = 44_100
        let seconds = 60
        let channels = 2
        let bits = 16
        let dataSize = sampleRate * seconds * channels * bits / 8
        var data = Data()
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)
        append16(1)                                   // PCM
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * channels * bits / 8))
        append16(UInt16(channels * bits / 8))
        append16(UInt16(bits))
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataSize))
        if amplitude == 0 {
            data.append(Data(repeating: 0, count: dataSize))
        } else {
            var samples = Data(capacity: dataSize)
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<(dataSize / 2) {
                let value = Bool.random(using: &generator) ? amplitude : -amplitude
                withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
            }
            data.append(samples)
        }
        try? data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private static func defaultOutputMuted() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(AppAudioChain.defaultOutputDevice(), &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private static func defaultOutputVolume() -> Float {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float = -1
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(AppAudioChain.defaultOutputDevice(), &address, 0, nil, &size, &value) == noErr else {
            return -1
        }
        return value
    }

    /// 打开真实的向导窗口：确认自适应高度生效、内容不会被裁
    static func logitechWizard() -> Int32 {
        _ = NSApplication.shared
        let state = AppState(preview: true)
        let controller = LogitechSetupWindowController(state: state)
        state.showLogitechSetup = true
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
        let window = controller.window
        let content = window.contentLayoutRect
        print(String(format: "可见=%@ 内容=%.0f×%.0f 窗口=%.0f×%.0f",
                     window.isVisible ? "是" : "否", content.width, content.height,
                     window.frame.width, window.frame.height))
        if let view = window.contentView?.superview,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/wizard-real.png"))
                print("截图：/tmp/wizard-real.png")
            }
        }
        state.dismissLogitechSetup()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        print(window.isVisible ? "✗ 关闭后窗口还在" : "✓ 关闭后窗口已收起")
        return 0
    }

    /// 存储清理机制：只动目录里的子项、进废纸篓，并且目录本身保留
    static func storageTrash() -> Int32 {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("aurora-storage-test-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for index in 0..<3 {
            try? Data(repeating: 0x41, count: 4096).write(to: dir.appendingPathComponent("file-\(index).bin"))
        }
        let outcome = StorageService.trashChildren(of: dir.path)
        let remaining = (try? fm.contentsOfDirectory(atPath: dir.path))?.count ?? -1
        let keptDirectory = fm.fileExists(atPath: dir.path)
        print("moved=\(outcome.moved) failed=\(outcome.failed) remaining=\(remaining) dirKept=\(keptDirectory)")

        // 顺手把测试文件从废纸篓里清掉，别在用户的废纸篓里留垃圾
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        for index in 0..<3 {
            try? fm.removeItem(at: trash.appendingPathComponent("file-\(index).bin"))
        }
        try? fm.removeItem(at: dir)

        // 废纸篓那一类走的是真删除，单独验一次
        let purge = fm.temporaryDirectory.appendingPathComponent("aurora-storage-purge-\(UUID().uuidString)")
        try? fm.createDirectory(at: purge, withIntermediateDirectories: true)
        for index in 0..<2 {
            try? Data(repeating: 0x42, count: 2048).write(to: purge.appendingPathComponent("junk-\(index).bin"))
        }
        let purgeOutcome = StorageService.removeChildren(of: purge.path)
        let purgeLeft = (try? fm.contentsOfDirectory(atPath: purge.path))?.count ?? -1
        try? fm.removeItem(at: purge)
        print("purge moved=\(purgeOutcome.moved) failed=\(purgeOutcome.failed) remaining=\(purgeLeft)")

        let ok = outcome.moved == 3 && remaining == 0 && keptDirectory
            && purgeOutcome.moved == 2 && purgeLeft == 0
        print(ok ? "✓ 清理只搬子项、目录保留；清空走真删除、失败 0" : "✗ 清理行为不符合预期")
        return ok ? 0 : 1
    }

    /// 扫描一遍存储页，确认每一项都能给出体积或明确原因
    static func storageScan() -> Int32 {
        _ = NSApplication.shared
        let state = AppState(preview: true)
        state.storage.scan()
        let deadline = Date().addingTimeInterval(60)
        while (state.storage.isScanning || state.storage.isFindingBigFiles) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        if let volume = state.storage.volume {
            print("磁盘：\(volume.name) 共 \(Fmt.bytes(UInt64(volume.total))) 可用 \(Fmt.bytes(UInt64(volume.free)))")
        }
        for item in state.storage.items {
            let note = item.note.map { " · \($0)" } ?? ""
            print(String(format: "  %-22@ %@%@", item.id as NSString,
                         (item.measured ? Fmt.bytes(UInt64(item.bytes)) : "—") as NSString, note as NSString))
        }
        print("大文件：\(state.storage.bigFiles.count) 个，工具：\(state.storage.tools.filter { $0.value }.keys.sorted())")
        return 0
    }

    /// DDC 写回验证：改一点亮度再读回来，确认不是「只读得到、写不进去」
    static func displayDDCWrite() -> Int32 {
        let manager = DDCManager()
        guard let id = DDCChannels.externalDisplayIDs().first,
              let channel = manager.channel(for: id),
              let original = channel.read(0x10) else {
            print("✗ 没有可用的 DDC 通道")
            return 1
        }
        let max = Int(original.max)
        let current = Int(original.current)
        let target = current >= max - 2 ? current - 2 : current + 2
        print("原始亮度 \(current)/\(max)，写入 \(target)")

        guard channel.write(0x10, value: UInt16(target)) else {
            print("✗ 写命令发送失败")
            return 1
        }
        Thread.sleep(forTimeInterval: 0.4)
        let afterWrite = channel.read(0x10)?.current ?? 0
        print("写入后读回 \(afterWrite)")

        _ = channel.write(0x10, value: original.current)
        Thread.sleep(forTimeInterval: 0.4)
        let restored = channel.read(0x10)?.current ?? 0
        print("还原后读回 \(restored)")

        let ok = Int(afterWrite) == target && Int(restored) == current
        print(ok ? "✓ DDC 写入与还原都生效" : "✗ DDC 写入没有生效")
        return ok ? 0 : 1
    }

    /// 卸载链路：造一个假 App + 假残留，确认两者都进废纸篓、残留识别没误伤
    static func appUninstall() -> Int32 {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let bundleID = "com.cary.aurora.uninstalltest"
        let bundle = home.appendingPathComponent("Applications/AuroraUninstallTest.app", isDirectory: true)
        let leftover = home.appendingPathComponent("Library/Caches/\(bundleID)", isDirectory: true)
        try? fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS", isDirectory: true), withIntermediateDirectories: true)
        try? fm.createDirectory(at: leftover, withIntermediateDirectories: true)
        (["CFBundleExecutable": "AuroraUninstallTest", "CFBundleIdentifier": bundleID,
          "CFBundleName": "AuroraUninstallTest"] as NSDictionary)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try? Data(repeating: 0x41, count: 4096).write(to: leftover.appendingPathComponent("junk.bin"))
        defer {
            try? fm.removeItem(at: bundle)
            try? fm.removeItem(at: leftover)
        }

        let service = AppInventoryService()
        let size = StorageService.measurePath(bundle.path)
        let app = InstalledApp(id: bundle.path, name: "AuroraUninstallTest", bundleID: bundleID,
                               version: "1.0", path: bundle.path, bytes: size, measured: true)

        var found: [AppLeftover] = []
        var failure: String?
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            found = await service.leftovers(for: app)
            failure = await service.uninstall(app: app, leftovers: found)
            done.signal()
        }
        while done.wait(timeout: .now()) != .success {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        print("识别残留 \(found.count) 项：\(found.map(\.path).map { ($0 as NSString).lastPathComponent })")
        let appGone = !fm.fileExists(atPath: bundle.path)
        let leftoverGone = !fm.fileExists(atPath: leftover.path)
        print("应用已移除=\(appGone) 残留已移除=\(leftoverGone) 失败=\(failure ?? "无")")

        // 从废纸篓里收走测试产物
        let trash = home.appendingPathComponent(".Trash")
        try? fm.removeItem(at: trash.appendingPathComponent("AuroraUninstallTest.app"))
        try? fm.removeItem(at: trash.appendingPathComponent(bundleID))

        let ok = failure == nil && appGone && leftoverGone && found.contains { $0.path == leftover.path }
        print(ok ? "✓ 卸载链路正常：本体与残留都进废纸篓" : "✗ 卸载链路不符合预期")
        return ok ? 0 : 1
    }

    /// 多屏亮度联动：分别验证「按比例」「保持差值」，最后把亮度还原
    static func displayBrightnessLink() -> Int32 {
        let service = DisplayService()
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))
        guard service.displays.count >= 2 else {
            print("· 只有一块屏幕，跳过")
            return 0
        }
        let source = service.displays.first(where: { $0.isMain }) ?? service.displays[0]
        guard let target = service.displays.first(where: { $0.id != source.id && $0.hasBrightness }) else {
            print("· 没有第二块可调亮度的屏，跳过")
            return 0
        }
        let s0 = source.brightness
        let t0 = target.brightness
        print(String(format: "起始：%@ %.2f → %@ %.2f", source.name, s0, target.name, t0))

        var failures = 0
        service.linkMode = .ratio
        let s1 = max(0.06, s0 * 0.5)
        service.setBrightness(s1, for: source.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let t1 = service.displays.first { $0.id == target.id }?.brightness ?? -1
        let expected1 = t0 * 0.5
        print(String(format: "按比例：源 %.2f 目标 %.2f（期望 %.2f）", s1, t1, expected1))
        if abs(t1 - expected1) > 0.03 { failures += 1 }

        service.setBrightness(s0, for: source.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let restored = service.displays.first { $0.id == target.id }?.brightness ?? -1
        print(String(format: "  比例还原后：源 %.2f 目标 %.2f（起始 %.2f）",
                     service.displays.first { $0.id == source.id }?.brightness ?? -1, restored, t0))

        service.linkMode = .offset
        let s2 = max(0.04, s0 - 0.08)
        service.setBrightness(s2, for: source.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let t2 = service.displays.first { $0.id == target.id }?.brightness ?? -1
        let expected2 = t0 - 0.08
        print(String(format: "保持差值：源 %.2f 目标 %.2f（期望 %.2f）", s2, t2, expected2))
        if abs(t2 - expected2) > 0.03 { failures += 1 }

        // 还原
        service.linkMode = .off
        service.setBrightness(s0, for: source.id)
        service.setBrightness(t0, for: target.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        print(failures == 0 ? "✓ 亮度联动（比例 / 差值）都按预期" : "✗ 亮度联动结果偏差过大")
        return failures == 0 ? 0 : 1
    }

    /// 摄像头：读权限状态，已授权时跑一次采集会话（不主动弹授权框）
    static func cameraCheck() -> Int32 {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let names = [0: "未决定", 1: "受限", 2: "已拒绝", 3: "已授权"]
        print("摄像头权限：\(names[status.rawValue] ?? "未知")（\(status.rawValue)）")
        if status == .notDetermined {
            print("· 第一次打开「画中画摄像头」时系统会弹一次权限框")
            return 0
        }
        guard status == .authorized else {
            print("✗ 权限被拒绝，画中画不会出现（系统设置 › 隐私与安全性 › 摄像头）")
            return 1
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video) else {
            print("✗ 没有可用摄像头")
            return 1
        }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { print("✗ 无法添加摄像头输入"); return 1 }
            session.addInput(input)
        } catch {
            print("✗ 摄像头输入创建失败：\(error.localizedDescription)")
            return 1
        }
        session.startRunning()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let running = session.isRunning
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        session.stopRunning()
        print("设备：\(device.localizedName) 分辨率 \(dims.width)×\(dims.height) 会话运行=\(running ? "是" : "否")")
        print(running ? "✓ 摄像头可用，画中画能出画" : "✗ 采集会话没能启动")
        return running ? 0 : 1
    }

    /// 抓一张主屏全屏图（自检 / 调试用：确认覆盖层落在哪儿）
    static func captureMainDisplayImage() -> CGImage? {
        var result: CGImage?
        var done = false
        Task { @MainActor in
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first {
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = display.width
                config.height = display.height
                config.showsCursor = false
                result = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            }
            done = true
        }
        let deadline = Date().addingTimeInterval(3)
        while !done && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return result
    }

    /// 按键显示：组合键是否完整（⇧⌘V / ⇧⌘4 / F1 / ⌘← …），胶囊宽度是否够
    static func keystrokeDisplay() -> Int32 {
        var failures = 0
        func check(_ name: String, _ actual: String?, _ expected: String) {
            let ok = actual == expected
            print(ok ? "✓ \(name)：\(actual ?? "nil")" : "✗ \(name)：\(actual ?? "nil")（期望 \(expected)）")
            if !ok { failures += 1 }
        }
        func event(_ keyCode: Int, _ flags: NSEvent.ModifierFlags = [],
                   chars: String = "", ignoring: String? = nil) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: chars,
                charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: UInt16(keyCode)
            )
        }
        func text(_ keyCode: Int, _ flags: NSEvent.ModifierFlags = [],
                  chars: String = "", ignoring: String? = nil) -> String? {
            guard let event = event(keyCode, flags, chars: chars, ignoring: ignoring) else { return nil }
            return KeystrokeOverlayService.displayText(for: event)
        }

        let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
        check("⇧⌘V", text(kVK_ANSI_V, cmdShift, chars: "V"), "⇧⌘V")
        check("⇧⌘4", text(kVK_ANSI_4, cmdShift, chars: "4"), "⇧⌘4")
        check("⌥⌘V 不变成 √", text(kVK_ANSI_V, [.command, .option], chars: "√", ignoring: "v"), "⌥⌘V")
        check("⌃⌥⇧⌘A", text(kVK_ANSI_A, [.control, .option, .shift, .command], chars: "A"), "⌃⌥⇧⌘A")
        check("F1", text(kVK_F1), "F1")
        check("⌘←", text(kVK_LeftArrow, [.command]), "⌘←")
        check("⇧⌘␣", text(kVK_Space, cmdShift, chars: " "), "⇧⌘␣")
        check("⌘⌫", text(kVK_Delete, [.command]), "⌘⌫")

        // 胶囊要能放下最长的组合键，不能被截断
        let long = "⌃⌥⇧⌘A"
        let size = KeystrokeOverlayService.panelSize(for: long)
        let textWidth = (long as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 21, weight: .semibold)
        ]).width
        check("胶囊宽度足够", size.width > textWidth + 40 ? "\(Int(size.width))pt" : "太窄 \(Int(size.width))pt", size.width > textWidth + 40 ? "\(Int(size.width))pt" : "太窄 \(Int(size.width))pt")

        print(failures == 0 ? "✓ 按键显示组合完整" : "✗ 按键显示有 \(failures) 项不符")
        return failures == 0 ? 0 : 1
    }

    /// 端到端：自己开一个输入框、把光标放到末尾，再用 CaretLocator 读回来比对
    /// （AX 查询必须在真 App 里跑，命令行沙箱会返回 cannotComplete）
    static func caretEndToEnd() -> Int32 {
        var lines: [String] = []
        var failures = 0
        func log(_ text: String) { lines.append(text); print(text) }
        func check(_ name: String, _ condition: Bool, _ detail: String) {
            log(condition ? "✓ \(name)：\(detail)" : "✗ \(name)：\(detail)")
            if !condition { failures += 1 }
        }
        func finish() -> Int32 {
            let text = lines.joined(separator: "\n") + "\n"
            try? text.write(toFile: "/tmp/aurora-caret-e2e.txt", atomically: true, encoding: .utf8)
            return failures == 0 ? 0 : 1
        }

        guard AXIsProcessTrusted() else {
            log("· 辅助功能未授权，跳过（系统设置 › 隐私与安全性 › 辅助功能 勾选 Aurora）")
            return finish()
        }

        let app = NSApplication.shared
        // main.swift 里已经 finishLaunching：AX 端口要等 App 启动完成才可用
        app.setActivationPolicy(.accessory)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 84),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "Aurora caret probe"
        let field = NSTextField(frame: NSRect(x: 24, y: 28, width: 320, height: 24))
        field.stringValue = "Aurora caret probe"
        field.font = .systemFont(ofSize: 13)
        window.contentView?.addSubview(field)
        window.setFrameOrigin(NSPoint(x: 320, y: 420))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        if let editor = window.fieldEditor(true, for: field) as? NSTextView {
            editor.setSelectedRange(NSRange(location: field.stringValue.count, length: 0))
        }
        app.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        let expected = window.convertToScreen(field.convert(field.bounds, to: nil))
        log("输入框屏幕矩形：\(expected)")
        log("AX 状态：\(CaretLocator.availability())  isActive=\(app.isActive) 前台=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")

        var probe = CaretLocator.probe()
        for attempt in 1...4 where probe.caret == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            probe = CaretLocator.probe()
            log("重试 \(attempt)：caret=\(String(describing: probe.caret)) note=\(probe.note)")
        }
        log("probe：caret=\(String(describing: probe.caret)) field=\(String(describing: probe.field)) secure=\(probe.isSecure) note=\(probe.note.isEmpty ? "-" : probe.note)")

        check("读到输入框", probe.field != nil && abs((probe.field?.minX ?? -999) - expected.minX) < 6,
              "AX \(String(describing: probe.field)) vs 实际 \(expected)")
        guard let caret = probe.caret else {
            log("✗ 没读到插入点（\(probe.note)）")
            window.orderOut(nil)
            return finish()
        }
        // 插入点会被撑成一行；不同 App 的 AX 行盒上下会有一行以内的偏差，给足余量
        let caretZone = NSRect(
            x: expected.minX - 6,
            y: expected.minY - 26,
            width: expected.width + 12,
            height: expected.height + 40
        )
        check("插入点在输入框内", caretZone.contains(caret), "光标 \(caret) / 期望区 \(caretZone)")
        check("插入点在文字末尾", caret.minX > expected.minX + 60 && caret.minX < expected.maxX, "光标 x=\(Int(caret.minX)) / 框 \(Int(expected.minX))…\(Int(expected.maxX))")

        let placement = MiniClipboardPlacement.resolve(size: MiniClipboardController.contentSize, probe: probe, mouse: .zero)
        check("锚点=光标", placement.anchor == .caret, placement.anchor.rawValue)
        check(
            "面板贴着光标（上方或下方）",
            abs(placement.frame.minY - (caret.maxY + MiniClipboardPlacement.gap)) < 1
                || abs(placement.frame.maxY - (caret.minY - MiniClipboardPlacement.gap)) < 1,
            "面板 \(placement.frame)"
        )
        check("面板不压住光标", !placement.frame.insetBy(dx: 2, dy: 2).contains(NSPoint(x: caret.midX, y: caret.midY)), "光标 \(caret)")

        if failures > 0 {
            log("— AX 明细 —")
            CaretLocator.diagnose().forEach { log($0) }
        }
        window.orderOut(nil)
        log(failures == 0 ? "✓ 插入点定位端到端通过" : "✗ 插入点定位有 \(failures) 项不符")
        return finish()
    }

    /// mini 剪切板定位：贴在光标上方 / 顶部翻到下方 / 边缘夹住 / 多屏 / 兜底
    static func miniClipboardPlacement() -> Int32 {
        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: String) {
            print(condition ? "✓ \(name)：\(detail)" : "✗ \(name)：\(detail)")
            if !condition { failures += 1 }
        }

        guard let screen = NSScreen.main else {
            print("✗ 没有主屏")
            return 1
        }
        let visible = screen.visibleFrame
        let size = MiniClipboardController.contentSize
        let gap = MiniClipboardPlacement.gap
        print("主屏可见区：\(Int(visible.minX)),\(Int(visible.minY)) \(Int(visible.width))×\(Int(visible.height))  面板 \(Int(size.width))×\(Int(size.height))")

        // 1) 屏幕中下部输入 → 面板贴光标上方，左边缘对齐光标
        let caret = NSRect(x: visible.minX + 260, y: visible.minY + 220, width: 4, height: 16)
        var result = MiniClipboardPlacement.resolve(size: size, probe: CaretProbe(caret: caret), mouse: .zero)
        check("锚点=光标", result.anchor == .caret, result.anchor.rawValue)
        check(
            "贴在光标上方",
            abs(result.frame.minY - (caret.maxY + gap)) < 0.5,
            "面板底部 \(Int(result.frame.minY)) / 光标顶部 \(Int(caret.maxY))"
        )
        check(
            "左边缘对齐光标",
            abs(result.frame.minX - caret.minX) < 0.5,
            "\(Int(result.frame.minX)) vs \(Int(caret.minX))"
        )
        check("整块留在屏内", visible.contains(result.frame), "\(result.frame)")

        // 2) 光标贴近屏幕顶部 → 翻到光标下方
        let topCaret = NSRect(x: visible.minX + 200, y: visible.maxY - 40, width: 4, height: 16)
        result = MiniClipboardPlacement.resolve(size: size, probe: CaretProbe(caret: topCaret), mouse: .zero)
        check(
            "顶部翻到光标下方",
            abs(result.frame.maxY - (topCaret.minY - gap)) < 0.5,
            "面板顶部 \(Int(result.frame.maxY)) / 光标底部 \(Int(topCaret.minY))"
        )
        check("仍在屏内", visible.contains(result.frame), "\(result.frame)")

        // 3) 光标贴着右边缘 → 水平夹回可见区
        let rightCaret = NSRect(x: visible.maxX - 6, y: visible.minY + 300, width: 4, height: 16)
        result = MiniClipboardPlacement.resolve(size: size, probe: CaretProbe(caret: rightCaret), mouse: .zero)
        check(
            "右边缘不外溢",
            result.frame.maxX <= visible.maxX - MiniClipboardPlacement.margin + 0.5,
            "面板右 \(Int(result.frame.maxX)) / 屏右 \(Int(visible.maxX))"
        )

        // 4) 只有控件矩形（读不到插入点）→ 落在控件下方
        let field = NSRect(x: visible.minX + 120, y: visible.maxY - 150, width: 320, height: 26)
        result = MiniClipboardPlacement.resolve(size: size, probe: CaretProbe(field: field), mouse: .zero)
        check("锚点=控件", result.anchor == .field, result.anchor.rawValue)
        check(
            "落在控件下方",
            abs(result.frame.maxY - (field.minY - gap)) < 0.5,
            "面板顶部 \(Int(result.frame.maxY)) / 控件底部 \(Int(field.minY))"
        )

        // 5) 什么都没有 → 老行为：鼠标所在屏、水平居中、偏上 12%
        let mouse = NSPoint(x: visible.midX, y: visible.midY)
        result = MiniClipboardPlacement.resolve(size: size, probe: CaretProbe(), mouse: mouse)
        check("兜底=鼠标", result.anchor == .mouse, result.anchor.rawValue)
        check("兜底水平居中", abs(result.frame.midX - visible.midX) < 0.5, "\(Int(result.frame.midX)) vs \(Int(visible.midX))")

        // 6) 多屏：锚点在副屏上时，面板跟着去副屏
        if NSScreen.screens.count > 1, let other = NSScreen.screens.first(where: { $0 !== screen }) {
            let rect = NSRect(x: other.frame.midX - 2, y: other.frame.midY, width: 4, height: 16)
            result = MiniClipboardPlacement.resolve(size: size, probe: CaretProbe(caret: rect), mouse: mouse)
            let landed = NSScreen.screens.first { $0.frame.contains(NSPoint(x: result.frame.midX, y: result.frame.midY)) }
            check("跟着锚点跨屏", landed === other, "落在 \(landed?.localizedName ?? "未知屏")（期望 \(other.localizedName)）")
        } else {
            print("· 只有一块屏幕，跳过跨屏检查")
        }

        // 7) 真实探针（从终端跑多半没有辅助功能权限，note 会说明原因）
        let live = CaretLocator.probe()
        print("实机探针：caret=\(String(describing: live.caret)) field=\(String(describing: live.field)) secure=\(live.isSecure) note=\(live.note.isEmpty ? "-" : live.note)")
        print("辅助功能权限：\(AXIsProcessTrusted() ? "已授权" : "未授权（会退回屏幕中上）")")
        if live.caret == nil && !live.note.isEmpty {
            print("· 想验证真实定位：在 Aurora.app 里按 ⇧⌘V（Aurora 已获辅助功能权限）")
        }

        print(failures == 0 ? "✓ mini 剪切板定位符合预期" : "✗ mini 剪切板定位有 \(failures) 项不符")
        return failures == 0 ? 0 : 1
    }

    /// 带壳录制：造一段测试视频 → 套壳导出 → 校验尺寸/时长并抽一帧出来看
    static func videoBezel() -> Int32 {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("aurora-bezel-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.mp4")
        guard writeTestVideo(to: source, width: 1280, height: 800, seconds: 2) else {
            print("✗ 生成测试视频失败")
            return 1
        }
        guard let frame = ScreenshotService.shared.defaultFrame else {
            print("✗ 没有可用的默认外壳")
            return 1
        }
        print("外壳：\(frame.device) \(frame.pixelWidth)×\(frame.pixelHeight)")

        // 先抽一帧源视频，确认测试素材本身有画面（否则问题出在合成而不是素材）
        let sourceGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        sourceGenerator.requestedTimeToleranceBefore = .zero
        sourceGenerator.requestedTimeToleranceAfter = .zero
        if let shot = try? sourceGenerator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil),
           let png = NSBitmapImageRep(cgImage: shot).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/bezel-source.png"))
            print("源视频抽帧：\(shot.width)×\(shot.height)")
        }

        let output = dir.appendingPathComponent("wrapped.mp4")
        var failure: String?
        var progressSeen = false
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            do {
                try await VideoBezel.wrap(source: source, frame: frame, to: output) { value in
                    if value > 0.05 { progressSeen = true }
                }
            } catch {
                failure = error.localizedDescription
            }
            done.signal()
        }
        while done.wait(timeout: .now()) != .success {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if let failure {
            print("✗ 套壳失败：\(failure)")
            return 1
        }

        let asset = AVURLAsset(url: output)
        var size = CGSize.zero
        var duration = 0.0
        var audioTracks = 0
        let probe = DispatchSemaphore(value: 0)
        Task {
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                size = (try? await track.load(.naturalSize)) ?? .zero
            }
            duration = (try? await asset.load(.duration).seconds) ?? 0
            audioTracks = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
            probe.signal()
        }
        while probe.wait(timeout: .now()) != .success {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        // 抽一帧存成 PNG，肉眼确认外壳与画面位置；顺便采样，
        // 免得「只剩外壳、屏幕全黑」这种回归又被当成成功
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var colourSpread = 0.0
        if let shot = try? generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil) {
            let rep = NSBitmapImageRep(cgImage: shot)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/bezel-frame.png"))
            }
            let points = [(0.25, 0.45), (0.45, 0.55), (0.62, 0.45), (0.78, 0.55)]
            let samples = points.compactMap { rep.colorAt(x: Int(Double(shot.width) * $0.0),
                                                          y: Int(Double(shot.height) * $0.1)) }
            // 取「同一像素内通道差」的最大值：黑屏时它接近 0，彩条时很大
            colourSpread = samples.map { color -> Double in
                let values = [color.redComponent, color.greenComponent, color.blueComponent].map(Double.init)
                return (values.max() ?? 0) - (values.min() ?? 0)
            }.max() ?? 0
        }

        let expectedWidth: CGFloat = min(VideoBezel.maxOutputWidth, CGFloat(frame.pixelWidth))
        let ok = abs(size.width - expectedWidth) < 2
            && size.height > 200
            && duration > 1.2
            && progressSeen
            && colourSpread > 0.2
        print(String(format: "输出 %.0f×%.0f，时长 %.2fs，音轨 %d，收到进度 %@，屏幕内色差 %.2f",
                     size.width, size.height, duration, audioTracks, progressSeen ? "是" : "否", colourSpread))
        print("抽帧：/tmp/bezel-frame.png")
        print(ok ? "✓ 带壳录制链路可用" : "✗ 带壳输出不符合预期")
        return ok ? 0 : 1
    }

    /// 造一段彩条测试视频（不依赖屏幕录制权限）
    private static func writeTestVideo(to url: URL, width: Int, height: Int, seconds: Double) -> Bool {
        let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4)
        guard let writer else { return false }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * 30)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            ) {
                // 横向彩条，方便一眼看出画面是否被拉伸/裁切
                let colors: [CGColor] = [
                    CGColor(red: 0.95, green: 0.3, blue: 0.3, alpha: 1),
                    CGColor(red: 0.3, green: 0.8, blue: 0.4, alpha: 1),
                    CGColor(red: 0.25, green: 0.5, blue: 0.95, alpha: 1),
                    CGColor(red: 0.95, green: 0.85, blue: 0.3, alpha: 1)
                ]
                for (bar, color) in colors.enumerated() {
                    context.setFillColor(color)
                    let barWidth = CGFloat(width) / CGFloat(colors.count)
                    context.fill(CGRect(x: CGFloat(bar) * barWidth, y: 0, width: barWidth, height: CGFloat(height)))
                }
                context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                let progress = CGFloat(index) / CGFloat(max(frames - 1, 1))
                context.fill(CGRect(x: 0, y: 0, width: CGFloat(width) * progress, height: 24))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        return writer.status == .completed
    }

    /// 通用二进制：造一个假的「通用 App」，走一遍扫描 → lipo → 重签 → 校验
    static func universalThin() -> Int32 {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appsDir = home.appendingPathComponent("Applications", isDirectory: true)
        try? fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
        let bundle = appsDir.appendingPathComponent("AuroraThinTest.app", isDirectory: true)
        try? fm.removeItem(at: bundle)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try? fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        // 借一个真实的双架构可执行文件当素材
        let source = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        guard fm.fileExists(atPath: source),
              (try? fm.copyItem(atPath: source, toPath: macOS.appendingPathComponent("AuroraThinTest").path)) != nil else {
            print("· 缺少素材（Chrome），跳过")
            return 0
        }
        let plist: [String: Any] = [
            "CFBundleExecutable": "AuroraThinTest",
            "CFBundleIdentifier": "com.cary.aurora.thintest",
            "CFBundleName": "AuroraThinTest",
            "CFBundlePackageType": "APPL"
        ]
        (plist as NSDictionary).write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true)
        defer { try? fm.removeItem(at: bundle) }

        let binary = macOS.appendingPathComponent("AuroraThinTest").path
        guard let before = MachOBinary.slices(at: binary)?.map(\.architecture).sorted() else {
            print("✗ 读不到测试应用的架构")
            return 1
        }
        print("瘦身前架构：\(before)")

        let service = UniversalService()
        var scanned: UniversalApp?
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await service.scan()
            scanned = service.apps.first { $0.id == bundle.path }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) != .success {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        guard let app = scanned else {
            print("✗ 扫描没有发现测试应用")
            return 1
        }
        print("识别为：\(app.name) 可回收 \(Fmt.bytes(UInt64(app.wasted))) 限制=\(app.blockReason ?? "无")")

        var failure: String?
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            failure = await service.thin(app)
            done.signal()
        }
        while done.wait(timeout: .now()) != .success {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if let failure {
            print("✗ 瘦身失败：\(failure)")
            return 1
        }

        let after = MachOBinary.slices(at: binary)?.map(\.architecture).sorted() ?? []
        let verify = CommandRunner.runSync("/usr/bin/codesign", ["--verify", bundle.path], timeout: 30)
        print("瘦身后架构：\(after) 签名校验=\(verify.ok ? "通过" : "失败")")
        let single = after == ["arm64"] && verify.ok

        // 再来一遍，走「勾选 + 批量」的路径。
        // 只勾测试应用本身：批量接口会照着 selection 直接动手，绝不能把真实 App 选进来
        try? fm.copyItem(atPath: source, toPath: macOS.appendingPathComponent("AuroraThinTest").path)
        var batchThinned = -1
        var batchSelected = -1
        var batchOnlyTestApp = false
        let batchDone = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await service.scan()
            service.selection = [bundle.path]
            batchSelected = service.selection.count
            batchOnlyTestApp = service.selectedApps.allSatisfy { $0.id == bundle.path }
            let summary = await service.thinSelection()
            batchThinned = summary.thinned
            batchDone.signal()
        }
        while batchDone.wait(timeout: .now()) != .success {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let batchArch = MachOBinary.slices(at: binary)?.map(\.architecture).sorted() ?? []
        print("批量：勾选 \(batchSelected) 项（只有测试应用：\(batchOnlyTestApp ? "是" : "否")），瘦身 \(batchThinned) 项，剩余架构 \(batchArch)")

        let ok = single && batchOnlyTestApp && batchThinned == 1 && batchArch == ["arm64"]
        print(ok ? "✓ 通用二进制瘦身链路可用（单个 + 全选批量）" : "✗ 瘦身结果不符合预期")
        return ok ? 0 : 1
    }

    /// 打印迁移页从 MonitorControl 扫到的字段（核对解析是否对得上）
    static func importScan() -> Int32 {
        let state = AppState(preview: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        state.imports.scan(displays: state.display.displays)
        for source in state.imports.sources where source.id == "monitorcontrol" {
            print("▸ \(source.name)：detected=\(source.detected)，字段 \(source.fields.count) 个")
            for field in source.fields {
                print("  · \(field.title) = \(field.valueText)  [\(field.detail)] → \(field.targetText) 选中=\(field.selected)")
            }
            if let note = source.note { print("  说明：\(note)") }
        }
        return 0
    }

    /// 打印每台显示器的 DDC 量程与当前值：确认写入量程和显示器报告的一致
    static func displayDDCReport() -> Int32 {
        let service = DisplayService()
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
        for item in service.displays {
            let channel = item.isBuiltIn ? "DisplayServices" : (DDCManager().channel(for: item.id) == nil ? "无" : "DDC")
            print("· \(item.name)：内置=\(item.isBuiltIn) 通道=\(channel) 可调亮度=\(item.hasBrightness) 报告最大值=\(item.ddcMax.map(String.init) ?? "—") 当前=\(String(format: "%.2f", item.brightness))")
            if !item.isBuiltIn, let ddc = DDCManager().channel(for: item.id) {
                for (label, vcp) in [("亮度", UInt8(0x10)), ("对比", UInt8(0x12)), ("音量", UInt8(0x62))] {
                    if let reply = ddc.read(vcp) {
                        print("    \(label) 0x\(String(vcp, radix: 16))：当前 \(reply.current) / 最大 \(reply.max)")
                    }
                }
            }
        }
        service.shutdown()
        return 0
    }

    /// 默认设备切换：走 AudioService 的真实代码路径，切完再读回系统值
    static func audioDefaultSwitch() -> Int32 {
        let service = AudioService()
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print(ok ? "✓ \(name)：\(detail)" : "✗ \(name)：\(detail)")
            if !ok { failures += 1 }
        }
        for output in [true, false] {
            let list = output ? service.outputs : service.inputs
            guard list.count > 1 else {
                print("· 跳过\(output ? "输出" : "输入")：可用设备不足")
                continue
            }
            let original = list.first(where: \.isDefault)
            guard let target = list.first(where: { !$0.isDefault }) else { continue }
            print("候选：\(target.name) (\(target.id))，当前默认：\(original?.name ?? "—")")
            let ok = service.setDefault(target)
            Thread.sleep(forTimeInterval: 0.4)
            service.refresh()
            let current = AudioService.defaultDevice(output: output)
            let badge = (output ? service.outputs : service.inputs).first(where: \.isDefault)
            check("切换到\(output ? "输出" : "输入") \(target.name)",
                  ok && current == target.id,
                  "返回 \(ok)，HAL=\(AudioService.name(of: current))，界面=\(badge?.name ?? "—")")
            if let original {
                _ = service.setDefault(original)
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        return failures == 0 ? 0 : 1
    }

    /// 在真实 AppState 环境里切默认设备：按应用音量轮询、权限监听等后台服务都在跑
    static func audioDefaultInApp() -> Int32 {
        _ = NSApplication.shared
        let state = AppState(preview: true)
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))

        var failures = 0
        for output in [true, false] {
            let list = output ? state.audio.outputs : state.audio.inputs
            guard list.count > 1, let original = list.first(where: \.isDefault),
                  let target = list.first(where: { !$0.isDefault }) else {
                print("· 跳过\(output ? "输出" : "输入")：设备不足")
                continue
            }
            print("\(output ? "输出" : "输入")：\(original.name) → \(target.name)")
            let ok = state.audio.setDefault(target)
            print("  setDefault 返回 \(ok)")
            for wait in [0.3, 1.2, 3.0] {
                RunLoop.main.run(until: Date().addingTimeInterval(wait))
                let hal = AudioService.name(of: AudioService.defaultDevice(output: output))
                let ui = (output ? state.audio.outputs : state.audio.inputs).first(where: \.isDefault)?.name ?? "—"
                print(String(format: "  +%.1fs HAL=%@ 界面=%@ %@", wait, hal, ui, (hal == target.name && ui == target.name) ? "✓" : "✗"))
            }
            let hal = AudioService.defaultDevice(output: output)
            let ui = (output ? state.audio.outputs : state.audio.inputs).first(where: \.isDefault)?.id
            if hal != target.id || ui != target.id { failures += 1 }
            _ = state.audio.setDefault(original)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        }
        print(failures == 0 ? "✓ AppState 环境下切换正常" : "✗ AppState 环境下切换有问题（\(failures) 项）")
        return failures == 0 ? 0 : 1
    }

    /// 只验证「监听器能不能把界面状态带过去」：绕过 AudioService，直接写 HAL 再等刷新
    static func audioDefaultListener() -> Int32 {
        let service = AudioService()
        let list = service.outputs
        guard list.count > 1, let original = list.first(where: \.isDefault),
              let target = list.first(where: { !$0.isDefault }) else {
            print("· 可用输出设备不足，跳过")
            return 0
        }
        print("初始界面默认：\(original.name)")

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = target.id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
        print("直接写 HAL：\(target.name) status=\(status)")
        // 监听回调走主队列，主线程 sleep 会把它堵住，必须转 runloop
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let viaListener = service.outputs.first(where: \.isDefault)?.name ?? "—"
        let hal = AudioService.name(of: AudioService.defaultDevice(output: true))
        print("1.5s 后（不手动 refresh）界面默认=\(viaListener)，HAL=\(hal)")

        // 还原
        var back = original.id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &back)
        let ok = viaListener == target.name
        print(ok ? "✓ 监听器把界面带到了新设备" : "✗ 界面没有跟随系统默认设备变化")
        return ok ? 0 : 1
    }

    /// 复现「按应用音量接管期间切换默认输出」：链路存在时默认设备会不会被改回去
    static func audioDefaultSwitchWithChain() -> Int32 {
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [waveFile(amplitude: 1)]
        try? player.run()
        defer { if player.isRunning { player.terminate() } }

        let perApp = PerAppAudioService()
        var itemID: String?
        for _ in 0..<15 where itemID == nil {
            usleep(300_000)
            perApp.refresh()
            itemID = perApp.items.first { $0.pid == player.processIdentifier }?.id
        }
        guard let itemID else {
            print("✗ 播放器没有出现在按应用列表里")
            perApp.shutdown()
            return 1
        }
        perApp.setVolume(0.5, for: itemID)
        Thread.sleep(forTimeInterval: 1.2)
        print("接管中：\(perApp.isControlled(itemID))")

        let service = AudioService()
        let list = service.outputs
        guard list.count > 1 else {
            print("· 只有一个输出设备，跳过")
            perApp.shutdown()
            return 0
        }
        let original = list.first(where: \.isDefault)
        guard let target = list.first(where: { !$0.isDefault }) else { perApp.shutdown(); return 0 }
        print("切换前默认：\(original?.name ?? "—")，目标：\(target.name)")
        let ok = service.setDefault(target)
        for delay in [0.2, 1.0, 2.0, 3.0] {
            Thread.sleep(forTimeInterval: delay)
            let now = AudioService.defaultDevice(output: true)
            print(String(format: "  +%.1fs 默认=%@（%@）", delay, AudioService.name(of: now), now == target.id ? "保持" : "被改回"))
        }
        let survived = AudioService.defaultDevice(output: true) == target.id
        perApp.shutdown()
        if let original { _ = service.setDefault(original) }
        print(survived && ok ? "✓ 接管期间切换默认输出保持生效" : "✗ 接管期间切换默认输出被打断")
        return survived && ok ? 0 : 1
    }

    /// 服务层端到端：静音音源 → 列表出现 → 调到 40% → 复位 → 链路拆除，
    /// 全程检查系统音量/静音没有被改动（AURORA_SOURCE=noise 用 ±1 LSB 噪底，听不见）
    static func audioServiceRoundTrip() -> Int32 {
        let noise = ProcessInfo.processInfo.environment["AURORA_SOURCE"] == "noise"
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [waveFile(amplitude: noise ? 1 : 0)]
        try? player.run()
        defer { if player.isRunning { player.terminate() } }

        let volumeBefore = defaultOutputVolume()
        let mutedBefore = defaultOutputMuted()

        let service = PerAppAudioService()
        var itemID: String?
        for _ in 0..<15 where itemID == nil {
            usleep(300_000)
            service.refresh()
            itemID = service.items.first { $0.pid == player.processIdentifier }?.id
        }
        guard let itemID else {
            print("✗ 列表里没出现播放器（静音源可能不算「正在发声」）")
            service.shutdown()
            return 1
        }
        print("列表出现：\(itemID)")

        service.setVolume(0.4, for: itemID)
        Thread.sleep(forTimeInterval: 2.0)
        let controlled = service.isControlled(itemID)
        let volumeDuring = defaultOutputVolume()
        let mutedDuring = defaultOutputMuted()

        service.setVolume(1.0, for: itemID)
        Thread.sleep(forTimeInterval: 1.2)
        let released = !service.isControlled(itemID)
        service.shutdown()

        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print(ok ? "✓ \(name)：\(detail)" : "✗ \(name)：\(detail)")
            if !ok { failures += 1 }
        }
        check("接管成功", controlled, "isControlled=\(controlled)")
        check("复位后拆除", released, "isControlled=\(!released)")
        check("系统音量不变", abs(volumeDuring - volumeBefore) < 0.02,
              String(format: "%.3f → %.3f", volumeBefore, volumeDuring))
        check("系统未被静音", mutedDuring == mutedBefore, "muted \(mutedBefore) → \(mutedDuring)")
        return failures == 0 ? 0 : 1
    }

    static func run() -> Int32 {
        var failures = 0
        func report(_ title: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "✓" : "✗") \(title)：\(detail)")
            if !ok { failures += 1 }
        }

        print("Aurora 自检 · \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("---------------------------------------------")

        // 显示器
        let display = DisplayService()
        report("显示器数量", !display.displays.isEmpty, "\(display.displays.count) 台")
        for item in display.displays {
            report(
                "  \(item.name)",
                item.hasBrightness || !item.isBuiltIn,
                "\(item.pixelLabel) @\(Int(item.refresh.rounded()))Hz 亮度 \(Fmt.percent(item.brightness)) 通道 \(item.isBuiltIn ? "DisplayServices" : (item.hasBrightness ? "DDC" : "无"))"
            )
        }
        if let first = display.displays.first, first.hasBrightness {
            let before = first.brightness
            let probe = max(0.05, before - 0.03)
            display.setBrightness(probe, for: first.id)
            Thread.sleep(forTimeInterval: 0.35)
            let after = DisplayServicesShim.brightness(of: first.id).map(Double.init) ?? before
            display.setBrightness(before, for: first.id)
            Thread.sleep(forTimeInterval: 0.25)
            report("亮度写入", abs(after - probe) < 0.02, String(format: "%.2f → %.2f → 已还原", before, after))
        }
        report("DDC 私有符号", IOAVShim.isAvailable, IOAVShim.isAvailable ? "IOAVService 可用" : "不可用")

        // 指针
        let trusted = AXIsProcessTrusted()
        report("辅助功能权限", trusted, trusted ? "已授权" : "未授权（鼠标接管将不可用）")

        // 资源
        let monitor = SystemMonitor()
        Thread.sleep(forTimeInterval: 1.2)
        monitor.sampleOnce()
        report("CPU 采样", monitor.cpu >= 0, Fmt.percent(monitor.cpu) + " · " + "\(monitor.perCore.count) 核")
        report("内存采样", monitor.memory.total > 0, "\(Fmt.bytes(monitor.memory.used)) / \(Fmt.bytes(monitor.memory.total))")
        report("网络采样", true, "↓\(Fmt.rate(monitor.network.download)) ↑\(Fmt.rate(monitor.network.upload))")
        report("磁盘采样", monitor.disk.total > 0, "可用 \(Fmt.bytes(monitor.disk.free)) / 共 \(Fmt.bytes(monitor.disk.total))")
        report("电池采样", monitor.battery != nil, monitor.battery.map { Fmt.percent($0.level) } ?? "无电池")
        report("进程采样", !monitor.processes.isEmpty, "\(monitor.processes.count) 个高占用进程")

        report("GPU 采样", monitor.gpu.available,
               monitor.gpu.available ? "\(monitor.gpu.cores) 核 · \(Fmt.percent(monitor.gpu.utilization)) · \(Fmt.bytes(monitor.gpu.memoryUsed))" : "不可用")
        report("神经网络引擎", true, monitor.neuralEngineAvailable ? "可用（系统未开放占用率遥测）" : "不可用")

        // 权限
        let permissions = PermissionService()
        report("辅助功能", permissions.accessibility, permissions.accessibility ? "已授权" : "未授权")
        report("屏幕录制", permissions.screenRecording, permissions.screenRecording ? "已授权" : "未授权")
        report("输入监控", permissions.inputMonitoring, permissions.inputMonitoring ? "已授权" : "未授权")
        report("完全磁盘访问", permissions.fullDiskAccess, permissions.fullDiskAccess ? "已授权" : "未授权")

        // 按应用音量
        let appAudio = PerAppAudioService()
        report("按应用音量", appAudio.isSupported, "\(appAudio.items.count) 个发声应用 · \(appAudio.controlledCount) 个已接管")

        // 剪贴板
        let clipboard = ClipboardService()
        report("剪贴板", true, "\(clipboard.items.count) 条历史 · \(clipboard.isEnabled ? "监听中" : "已关闭")")

        // 声音
        let audio = AudioService()
        report("音频设备", !audio.outputs.isEmpty, "\(audio.outputs.count) 输出 / \(audio.inputs.count) 输入 · 默认 \(audio.defaultOutputName)")

        // 用量
        let ai = AIUsageService()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let providers = ai.providers
        report("AI用量", !providers.isEmpty, providers.map { "\($0.name) \(Fmt.tokens($0.weekTokens))" }.joined(separator: " · "))

        // 自定义动作
        let custom = CustomActionService()
        report("自定义动作", true, "\(custom.actions.count) 个已配置")

        // 右键菜单
        let menu = ContextMenuService()
        report("右键菜单项", !menu.items.isEmpty, "\(menu.items.count) 项可管理")
        print("  前 5 项：\(menu.items.prefix(5).map { $0.title }.joined(separator: " / "))")

        // 桌面
        let desktop = DesktopService()
        report("桌面图标状态", true, desktop.iconsVisible ? "显示" : "隐藏")
        report("访达显示项", true, "隐藏文件 \(desktop.showHiddenFiles ? "显示" : "隐藏") · 扩展名 \(desktop.showAllExtensions ? "显示" : "隐藏")")

        // 屏幕检测窗口（不显示，只验证无边框窗口能成为 key window，否则 ESC 收不到）
        let testWindow = ScreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        report("屏幕检测窗口", testWindow.canBecomeKey, testWindow.canBecomeKey ? "可接收 ESC" : "无法成为 key window")

        // 设备枚举
        let hid = HIDDeviceService()
        report("键盘识别", !hid.keyboards.isEmpty, hid.keyboards.map(\.name).joined(separator: " · "))
        report("指针识别", true, hid.pointers.isEmpty ? "仅内建触控板" : hid.pointers.map(\.name).joined(separator: " · "))

        // 配置导入
        let imports = ImportService()
        imports.scan(displays: display.displays)
        let detected = imports.sources.filter(\.detected)
        report(
            "可导入来源",
            true,
            detected.isEmpty ? "未检测到同类工具" : detected.map { "\($0.name)(\($0.fields.count))" }.joined(separator: " · ")
        )

        print("---------------------------------------------")
        print(failures == 0 ? "全部通过" : "\(failures) 项需要关注")
        return failures == 0 ? 0 : 1
    }


    /// 打印 AI 用量适配结果（开发用）
    static func aiScan() -> Int32 {
        let service = AIUsageService()
        var waited = 0
        while service.isScanning || service.providers.isEmpty, waited < 60 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            waited += 1
        }
        print("本周合计 \(Fmt.tokens(service.weekTotal)) · 今日 \(Fmt.tokens(service.todayTotal))")
        for provider in service.providers {
            let quota = provider.quotaWindows
                .map { "\($0.label) \(Int($0.usedPercent))%" }
                .joined(separator: " / ")
            print("· \(provider.name) [\(provider.source == .localLog ? "data" : "detect")] week=\(provider.weekTokens) today=\(provider.todayTokens) sessions=\(provider.sessionCount) \(quota) \(provider.note ?? "")")
        }
        return service.withData.isEmpty ? 1 : 0
    }

    /// 打印外部设备（开发用）
    static func externalDevices() -> Int32 {
        let service = DeviceService()
        var waited = 0
        while service.devices.isEmpty, waited < 40 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            waited += 1
        }
        print("外部设备 \(service.devices.count) 个：")
        for device in service.devices {
            print("· \(device.name) · \(device.kindLabel) · \(device.connection) · model=\(device.model ?? "—") · battery=\(device.battery.map { "\($0)%" } ?? "—") · parts=\(device.batteryParts.map { "\($0.label)\($0.level)" }.joined(separator: ",")) · \(device.detail ?? "")")
        }
        return service.devices.isEmpty ? 1 : 0
    }

    // MARK: - 新增模块自检

    /// 剪贴板：旧版 JSON 兼容 + 颜色互转
    static func clipboardCompat() -> Int32 {
        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: String) {
            print(condition ? "✓ \(name)：\(detail)" : "✗ \(name)：\(detail)")
            if !condition { failures += 1 }
        }

        let legacy = """
        [{"id":"11111111-1111-1111-1111-111111111111","kind":"text","text":"hello aurora",
          "imageFile":null,"date":760000000,"pinned":true,"source":"Safari"}]
        """
        let decoded = (try? JSONDecoder().decode([ClipItem].self, from: Data(legacy.utf8))) ?? []
        check("旧记录可解码", decoded.count == 1, "条目 \(decoded.count)")
        if let item = decoded.first {
            check("旧字段保留", item.text == "hello aurora" && item.pinned, "pinned=\(item.pinned)")
            check(
                "新字段有默认值",
                item.copies == 1 && item.byteCount == 0 && item.digest.isEmpty && item.sourceBundle.isEmpty,
                "copies=\(item.copies)"
            )
            let round = (try? JSONEncoder().encode([item])).flatMap {
                try? JSONDecoder().decode([ClipItem].self, from: $0)
            }
            check("重新编码可往返", round?.first?.id == item.id, "id 一致")
        }

        let color = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        let hex = color.hexString
        let restored = NSColor(hexString: hex)
        check("颜色十六进制往返", hex == "#3399E6" && restored != nil, "\(hex)")

        return failures == 0 ? 0 : 1
    }

    /// 清洁模式：普通按键必须被吞掉，⌃⌥⌘K 触发解锁
    static func keyboardClean() -> Int32 {
        let engine = CleanKeyboardEngine()
        var unlocked = false
        engine.onUnlock = { unlocked = true }

        func key(_ code: Int64, _ flags: CGEventFlags) -> CGEvent? {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)
            event?.flags = flags
            return event
        }

        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: String) {
            print(condition ? "✓ \(name)：\(detail)" : "✗ \(name)：\(detail)")
            if !condition { failures += 1 }
        }

        if let event = key(0, []) {
            let output = engine.process(type: .keyDown, event: event)
            check("普通按键被拦截", output == nil, "返回 nil")
        }
        if let event = key(0, [.maskControl, .maskAlternate, .maskCommand]) {
            let output = engine.process(type: .keyDown, event: event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            check("⌃⌥⌘A 不解锁", !unlocked, "仍然锁定")
            check("解锁组合被拦截", output == nil, "返回 nil")
        }
        if let event = key(0x28, [.maskControl, .maskAlternate, .maskCommand]) {
            _ = engine.process(type: .keyDown, event: event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            check("⌃⌥⌘K 触发解锁", unlocked, "回调已执行")
        }

        if let event = CGEvent(source: nil) {
            let output = engine.process(type: .flagsChanged, event: event)
            check("修饰键也拦截", output == nil, "返回 nil")
        }

        engine.stop()
        return failures == 0 ? 0 : 1
    }

    /// 设置页 →「欢迎与权限设置」：应先收起主面板，再打开欢迎页
    static func welcomeFlow() -> Int32 {
        let state = AppState(preview: true)
        var dismissed = false
        state.onDismissMainPanel = { dismissed = true }
        state.openWelcome()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let opened = state.showWelcome
        print(dismissed ? "✓ 主面板已收起" : "✗ 没有收起主面板")
        print(opened ? "✓ 欢迎页已打开" : "✗ 欢迎页没有打开")
        state.showWelcome = false
        return dismissed && opened ? 0 : 1
    }

    /// 端到端：真的往系统剪贴板写内容，等轮询把它记下来
    static func clipboardE2E() -> Int32 {
        let service = ClipboardService()
        let pasteboard = NSPasteboard.general
        var failures = 0
        var created: [UUID] = []

        func check(_ name: String, _ condition: Bool, _ detail: String) {
            print(condition ? "✓ \(name)：\(detail)" : "✗ \(name)：\(detail)")
            if !condition { failures += 1 }
        }

        func wait() { RunLoop.main.run(until: Date().addingTimeInterval(1.6)) }

        print("启用=\(service.isEnabled) 现有条目=\(service.items.count)")

        // 1. 文本 + 去重
        let token = "aurora-e2e-\(Int(Date().timeIntervalSince1970))"
        for _ in 0..<2 {
            pasteboard.clearContents()
            pasteboard.setString(token, forType: .string)
            wait()
        }
        let textItem = service.items.first { $0.text == token }
        check("文本被记录", textItem != nil, token)
        check("重复复制合并", textItem?.copies == 2, "次数 \(textItem?.copies ?? -1)")
        if let item = textItem { created.append(item.id) }

        // 2. 富文本
        let richToken = "aurora-rich-\(Int(Date().timeIntervalSince1970))"
        let attributed = NSAttributedString(
            string: richToken,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 15)]
        )
        if let rtf = attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            pasteboard.clearContents()
            pasteboard.setData(rtf, forType: .rtf)
            pasteboard.setString(richToken, forType: .string)
            wait()
            let richItem = service.items.first { $0.text == richToken }
            check("富文本被记录", richItem?.kind == .rich, "类型 \(richItem?.kind.rawValue ?? "无")")
            check("RTF 落盘", richItem?.rtfFile != nil, "有 RTF 文件")
            if let item = richItem { created.append(item.id) }
        }

        // 3. 图片
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill()
        image.unlockFocus()
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            wait()
            let imageItem = service.items.first { $0.kind == .image }
            check("图片被记录", imageItem != nil, "图片条目")
            if let item = imageItem {
                check("图片文件存在", service.imageURL(for: item).map { FileManager.default.fileExists(atPath: $0.path) } ?? false, "clips/")
                created.append(item.id)
            }
        }

        for id in created {
            if let item = service.item(with: id) { service.delete(item) }
        }
        print("清理后条目=\(service.items.count)")
        return failures == 0 ? 0 : 1
    }

    /// 设备枚举：打印当前识别到的键盘与指针
    static func deviceScan() -> Int32 {
        let service = HIDDeviceService()
        service.refresh()
        let keyboard = KeyboardService()
        print("键盘 \(service.keyboards.count) 个：")
        for device in service.keyboards {
            print("  · \(device.name) · \(device.transportLabel) · \(device.vendorLabel) · 类型键 \(device.keyboardTypeKey) · 当前类型 \(keyboard.storedType(for: device).title)")
        }
        print("指针 \(service.pointers.count) 个：")
        for device in service.pointers {
            print("  · \(device.name) · \(device.transportLabel) · \(device.vendorLabel) · 电量 \(device.battery.map { "\($0)%" } ?? "—")")
        }
        return service.keyboards.isEmpty ? 1 : 0
    }

    /// 画布交互自测：用合成鼠标事件驱动 CanvasMouseNSView，
    /// 确认「按住拖动」能连续出点、形状只保留起终点、单击不出图形。
    static func canvasInteraction() -> Int32 {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print(ok ? "✓ \(name)：\(detail)" : "✗ \(name)：\(detail)")
            if !ok { failures += 1 }
        }

        func makeView(tool: AnnotationTool, onDraft: @escaping (Annotation?) -> Void,
                      onCommit: @escaping (Annotation) -> Void) -> CanvasMouseNSView {
            let view = CanvasMouseNSView()
            view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            view.representable = CanvasMouseView(
                tool: tool, color: .red, strokeWidth: 4, annotations: [], draft: nil,
                onDraft: onDraft, onCommit: onCommit, onMoveStart: {}, onMove: { _, _ in },
                onSelect: { _ in }, onTap: { _ in }
            )
            return view
        }

        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }

        // 1. 画笔：按住拖过 10 个点
        var drafts: [Int] = []
        var committed: Annotation?
        let pen = makeView(tool: .pen, onDraft: { draft in
            if case .stroke(let stroke)? = draft { drafts.append(stroke.points.count) }
        }, onCommit: { committed = $0 })
        pen.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 100, y: 150)))
        for step in 1...10 {
            pen.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 100 + CGFloat(step) * 12, y: 150 + CGFloat(step) * 4)))
        }
        pen.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 220, y: 190)))
        if case .stroke(let stroke)? = committed {
            check("画笔拖动累积点", stroke.points.count >= 8, "\(stroke.points.count) 点，草稿回调 \(drafts.count) 次")
            check("画笔首点正确", abs(stroke.points[0].x - 0.25) < 0.01, "x=\(String(format: "%.3f", stroke.points[0].x))")
        } else {
            check("画笔拖动累积点", false, "没有提交笔画")
        }

        // 2. 矩形：拖拽过程中只保留起终点
        var rectDraftCounts: [Int] = []
        var rectCommitted: Annotation?
        let rect = makeView(tool: .rect, onDraft: { draft in
            if case .stroke(let stroke)? = draft { rectDraftCounts.append(stroke.points.count) }
        }, onCommit: { rectCommitted = $0 })
        rect.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 50, y: 50)))
        for step in 1...6 {
            rect.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 50 + CGFloat(step) * 10, y: 50 + CGFloat(step) * 10)))
        }
        rect.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 110, y: 110)))
        if case .stroke(let stroke)? = rectCommitted {
            check("矩形只保留两点", stroke.points.count == 2, "\(stroke.points.count) 点，草稿点数 \(rectDraftCounts)")
            check("矩形跟随拖动", abs(stroke.points[1].x - 0.275) < 0.02, "终点 x=\(String(format: "%.3f", stroke.points[1].x))")
        } else {
            check("矩形只保留两点", false, "没有提交矩形")
        }

        // 3. 单击（无拖动）不应产生标注
        var clickCommitted = false
        let pen2 = makeView(tool: .pen, onDraft: { _ in }, onCommit: { _ in clickCommitted = true })
        pen2.mouseDown(with: event(.leftMouseDown, at: NSPoint(x: 30, y: 30)))
        pen2.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: 30, y: 30)))
        check("单击不成形", !clickCommitted, clickCommitted ? "单击却提交了标注" : "已忽略")

        return failures == 0 ? 0 : 1
    }

    /// 录屏往返自测：真录 N 秒 → 停止 → 校验落盘的 mp4 有视频轨且大小正常
    static func recorderRoundTrip(seconds: Double) -> Int32 {
        let service = RecorderService.shared
        guard service.hasScreenPermission else {
            print("✗ 没有屏幕录制权限，跳过")
            return 2
        }
        // 自测不碰麦克风 / 摄像头，避免弹权限框
        service.recordMic = false
        service.pipCamera = false
        service.highlightClicks = false
        service.showKeystrokes = false
        // 源列表是异步扫描的，等它出来再开始
        var waited = 0.0
        while service.sources.isEmpty && waited < 5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            waited += 0.1
            if waited > 1.5 { service.refreshSources() }
        }
        guard !service.sources.isEmpty else { print("✗ 没有可用录制源（可能未授权屏幕录制）"); return 2 }
        service.start()

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let error = service.lastError { print("✗ 启动失败：\(error)"); return 1 }
            if service.isRecording { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        guard service.isRecording else { print("✗ 录制没有开始"); return 1 }

        let stopAt = Date().addingTimeInterval(seconds)
        while Date() < stopAt { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        service.stop()

        let finishDeadline = Date().addingTimeInterval(20)
        while service.lastMovieURL == nil && service.lastError == nil && Date() < finishDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        guard let url = service.lastMovieURL else {
            print("✗ 保存失败：\(service.lastError ?? "未知错误")")
            return 1
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        var detail = ""
        var ok = size > 10_000
        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks
        let video = tracks.filter { $0.mediaType == .video }
        let audio = tracks.filter { $0.mediaType == .audio }
        if video.isEmpty { ok = false }
        let duration = CMTimeGetSeconds(asset.duration)
        detail = "大小 \(size) 字节 · 视频轨 \(video.count) · 音频轨 \(audio.count) · 时长 \(String(format: "%.1f", duration))s"
        print(ok ? "✓ 录制保存成功：\(url.lastPathComponent) \(detail)" : "✗ 录制文件异常：\(detail)")
        // 清理自测文件
        try? FileManager.default.removeItem(at: url)
        return ok ? 0 : 1
    }
}
