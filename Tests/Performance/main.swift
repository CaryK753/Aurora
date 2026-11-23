import Foundation

func readCounters() -> ProcessCPUCounters {
    var ticks: UInt64 = 0, startedAt: UInt64 = 0
    precondition(read_cpu_ticks(&ticks, &startedAt) == 0)
    return ProcessCPUCounters(ticks: ticks, startedAt: startedAt)
}

let time0 = ProcessInfo.processInfo.systemUptime
var ns0: UInt64 = 0, ns1: UInt64 = 0
precondition(read_cpu_nanoseconds(&ns0) == 0)
let counters0 = readCounters()
var seed: UInt64 = 1
while ProcessInfo.processInfo.systemUptime - time0 < 0.4 {
    seed = busy_work(seed)
}
let counters1 = readCounters()
precondition(read_cpu_nanoseconds(&ns1) == 0)
let elapsed = ProcessInfo.processInfo.systemUptime - time0
let expected = Double(ns1 - ns0) / (elapsed * 1e9) * 100
let measured = counters1.percent(since: counters0, elapsed: elapsed)
precondition(expected > 50 && abs(expected - measured) <= 3, "reference=\(expected), measured=\(measured)")
precondition(counters1.percent(since: nil, elapsed: elapsed) == 0)
precondition(counters1.percent(since: .init(ticks: 0, startedAt: counters1.startedAt ^ 1), elapsed: elapsed) == 0)
precondition(counters1.percent(since: .init(ticks: counters1.ticks + 1, startedAt: counters1.startedAt), elapsed: elapsed) == 0)
precondition(counters1.percent(since: counters0, elapsed: 0) == 0)
print(String(format: "PASS: CPU reference %.2f%%, corrected %.2f%%; initial/reset/reused PID", expected, measured))

var input: [ProcessSample] = (1...8).map { i in
    let memory = UInt64(127 + i) * 1_048_576
    return ProcessSample(id: pid_t(i), name: "", cpu: 1, memory: memory)
}
input.append(ProcessSample(id: 9, name: "", cpu: 0, memory: 2_147_483_648))
input.append(ProcessSample(id: 10, name: "", cpu: 0.1, memory: 1))
var lookups: [pid_t: Int] = [:]
let rankings = ProcessRankings(samples: Array(input.reversed())) {
    lookups[$0, default: 0] += 1
    return "fixture-\($0)"
}
precondition(rankings.cpu.map(\.id) == (1...8).map { pid_t($0) })
precondition(rankings.memory.first?.id == 9 && rankings.memory.first?.name == "fixture-9")
precondition(rankings.memory.map(\.id) == [9,8,7,6,5,4,3,2])
precondition(lookups.count == 9 && lookups.values.allSatisfy { $0 == 1 })
print("PASS: independent rankings, idle 2 GiB first for memory; 9 unique name lookups")

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }

    func update<Result>(_ change: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return change(&value)
    }
    var current: Value { update { $0 } }
}

@MainActor
func waitUntil(_ condition: () -> Bool) {
    let deadline = ProcessInfo.processInfo.systemUptime + 4
    while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    precondition(condition(), "timed out waiting for background refresh")
}

MainActor.assumeIsolated {
    let reads = Locked<[Int]>([])
    let started = DispatchSemaphore(value: 0)
    let unblock = DispatchSemaphore(value: 0)
    let coalescer = BackgroundSnapshot<Int, Int>(label: "fixture.probe") { input in
        precondition(!Thread.isMainThread)
        reads.update { $0.append(input) }
        if input == 1 {
            started.signal()
            precondition(unblock.wait(timeout: .now() + 3) == .success)
        }
        return input
    }
    precondition(coalescer.request(1) { _ in preconditionFailure("stale reading delivered") })
    precondition(started.wait(timeout: .now() + 2) == .success)
    precondition(!coalescer.request(2) { _ in preconditionFailure("overlapping reading delivered") })
    coalescer.requestLatest(3) { _ in preconditionFailure("superseded reading delivered") }
    var received: Int?
    coalescer.requestLatest(4) {
        precondition(Thread.isMainThread)
        received = $0
    }
    unblock.signal()
    waitUntil { received == 4 }
    precondition(reads.current == [1, 4])
    print("PASS: reads run off-main; newest-only coalescing and main-thread publication")

    let power = Locked((BatteryStats(level: 0.8, isPluggedIn: true), 0))
    let detailReads = Locked(0)
    let diskReads = Locked(0)
    let holdDisk = DispatchSemaphore(value: 0)
    let monitor = SystemMonitor(dashboardVisible: false, pollInterval: 0.3, readPowerState: {
        precondition(!Thread.isMainThread)
        return power.update { $0.1 += 1; return $0.0 }
    }, readBatteryDetails: { battery in
        precondition(!Thread.isMainThread)
        detailReads.update { $0 += 1 }
        battery.health = 0.95
    }, diskCapacityInterval: 30, readDiskCapacity: {
        precondition(!Thread.isMainThread)
        diskReads.update { $0 += 1 }
        precondition(holdDisk.wait(timeout: .now() + 4) == .success)
        return DiskCapacity(total: 1000, free: 432)
    })
    var dashboardSamples = 0
    var lastUptime: TimeInterval = 0
    var lastBatteryEvent: BatteryStats?
    let dashboardSub = monitor.$dashboard.dropFirst().sink {
        precondition(Thread.isMainThread)
        if $0.uptime != lastUptime { dashboardSamples += 1; lastUptime = $0.uptime }
    }
    let batterySub = monitor.$battery.sink {
        precondition(Thread.isMainThread)
        lastBatteryEvent = $0
    }
    defer { dashboardSub.cancel(); batterySub.cancel() }

    waitUntil { lastBatteryEvent?.level == 0.8 }
    power.update { $0.0.isPluggedIn = false; $0.0.level = 0.1 }
    waitUntil { lastBatteryEvent?.level == 0.1 }
    precondition(lastBatteryEvent?.isPluggedIn == false)
    precondition(monitor.memory.total == 0 && dashboardSamples == 0 && detailReads.current == 0 && diskReads.current == 0)
    print("PASS: hidden: only background power reads; unplugged/10% delivered")

    monitor.setDashboardVisible(true)
    monitor.setDashboardVisible(true)
    waitUntil { dashboardSamples >= 1 }
    precondition(dashboardSamples == 1 && detailReads.current == 1 && monitor.memory.total > 0)
    precondition(monitor.battery?.health == 0.95)
    waitUntil { dashboardSamples >= 3 && diskReads.current == 1 }
    precondition(monitor.disk.total == 0)
    holdDisk.signal()
    waitUntil { monitor.disk.total == 1000 }
    precondition(monitor.disk.free == 432)
    precondition(detailReads.current == 1 && monitor.battery?.health == 0.95)
    print("PASS: blocked disk capacity does not stall sampling; capacity publishes when ready")

    monitor.setDashboardVisible(false)
    let samplesAtHide = dashboardSamples
    let cpuHistoryCount = monitor.cpuHistory.count
    let netHistoryCount = monitor.netHistory.count
    power.update { $0.0.isPluggedIn = true; $0.0.level = 0.11 }
    waitUntil { lastBatteryEvent?.level == 0.11 }
    precondition(dashboardSamples == samplesAtHide && detailReads.current == 1 && diskReads.current == 1)
    precondition(lastBatteryEvent?.isPluggedIn == true)

    monitor.setDashboardVisible(true)
    waitUntil { dashboardSamples == samplesAtHide + 1 }
    precondition(detailReads.current == 2)
    precondition(monitor.network.download == 0 && monitor.network.upload == 0)
    precondition(monitor.disk.readRate == 0 && monitor.disk.writeRate == 0 && monitor.disk.total == 1000)
    precondition(monitor.processRankings.cpu.isEmpty && monitor.cpuHistory.count == cpuHistoryCount)
    precondition(monitor.netHistory.count == netHistoryCount)
    waitUntil { dashboardSamples >= samplesAtHide + 2 }
    precondition(monitor.cpuHistory.count > cpuHistoryCount && monitor.netHistory.count > netHistoryCount)
    precondition(diskReads.current == 1)
    print("PASS: reopening resets rate baselines, resumes sampling and retains disk capacity")
}

MainActor.assumeIsolated {
    let attempts = Locked(0)
    let grant = DispatchSemaphore(value: 0)
    let permission = PermissionService {
        precondition(!Thread.isMainThread)
        let attempt = attempts.update { $0 += 1; return $0 }
        if attempt == 1 { precondition(grant.wait(timeout: .now() + 3) == .success) }
        return .init(snapshot: PermissionSnapshot(accessibility: attempt > 1, screenRecording: false,
                     inputMonitoring: false, disk: .denied), camera: .unknown, microphone: .unknown)
    }
    var permissionEvents = 0
    let sub = permission.$statuses.dropFirst().sink { statuses in
        precondition(Thread.isMainThread && statuses["accessibility"] == .granted)
        permissionEvents += 1
    }
    defer { sub.cancel() }
    permission.recheck()
    permission.recheck()
    grant.signal()
    waitUntil { permission.accessibility && permissionEvents == 1 }
    precondition(attempts.current == 2)
    permission.refresh()
    waitUntil { attempts.current == 3 }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
    precondition(permissionEvents == 1)
    print("PASS: permission recheck drops a stale in-flight reading; unchanged snapshot is not republished")

    let vpnReads = Locked(0)
    let vpn = VPNStatusService(interval: 0.12) {
        precondition(!Thread.isMainThread)
        vpnReads.update { $0 += 1 }
        return VPNStatus(connected: true, name: "fixture VPN")
    }
    var vpnEvents = 0
    let vpnSub = vpn.$status.dropFirst().sink { _ in
        precondition(Thread.isMainThread)
        vpnEvents += 1
    }
    defer { vpnSub.cancel() }
    vpn.setOverviewVisible(true)
    precondition(vpnReads.current == 0)
    vpn.setPanelVisible(true)
    waitUntil { vpn.status.summary == "fixture VPN" }
    waitUntil { vpnReads.current >= 2 }
    precondition(vpnEvents == 1)
    vpn.setPanelVisible(false)
    let count = vpnReads.current
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    precondition(vpnReads.current == count)
    vpn.setOverviewVisible(false)
    vpn.setPanelVisible(true)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.17))
    precondition(vpnReads.current == count)
    print("PASS: VPN reads only on visible overview, refreshes by TTL, skips unchanged publications")
}
