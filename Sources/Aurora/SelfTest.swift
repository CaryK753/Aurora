//  SelfTest.swift
//  Aurora — 自检模式：`Aurora --selftest` 逐项验证底层能力是否可用

import AppKit
import AVFoundation
import ApplicationServices
import os
import CoreAudio
import AudioToolbox
import ServiceManagement

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
