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

MainActor.assumeIsolated {
    var simulatedBattery = BatteryStats(level: 0.8, isPluggedIn: true)
    var powerReads = 0
    var detailReads = 0
    let monitor = SystemMonitor(dashboardVisible: false, pollInterval: 0.25, readPowerState: {
        powerReads += 1
        return simulatedBattery
    }, readBatteryDetails: { battery in
        detailReads += 1
        battery.health = 0.95
    })
    var dashboardSamples = 0
    var lastBatteryEvent: BatteryStats?
    let uptimeSub = monitor.$uptime.dropFirst().sink { _ in dashboardSamples += 1 }
    let batterySub = monitor.$battery.sink { lastBatteryEvent = $0 }
    defer { uptimeSub.cancel(); batterySub.cancel() }

    func waitUntil(_ condition: () -> Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        precondition(condition(), "timed out waiting for sampling")
    }

    precondition(monitor.memory.total == 0 && lastBatteryEvent?.level == 0.8)
    simulatedBattery.isPluggedIn = false
    simulatedBattery.level = 0.1
    waitUntil { powerReads >= 4 }
    precondition(dashboardSamples == 0 && detailReads == 0)
    precondition(lastBatteryEvent?.level == 0.1 && lastBatteryEvent?.isPluggedIn == false)
    print("PASS: cold-hidden 0 dashboard samples / 0 battery-detail reads; unplugged/10% delivered")

    monitor.setDashboardVisible(true)
    precondition(dashboardSamples == 1 && detailReads == 1 && monitor.memory.total > 0)
    precondition(monitor.battery?.health == 0.95)
    monitor.setDashboardVisible(true)
    precondition(dashboardSamples == 1) // repeat show is idempotent
    waitUntil { dashboardSamples >= 3 }
    precondition(detailReads == 1 && monitor.battery?.health == 0.95)

    monitor.setDashboardVisible(false)
    let samplesAtHide = dashboardSamples
    let readsAtHide = powerReads
    let cpuHistoryCount = monitor.cpuHistory.count
    let netHistoryCount = monitor.netHistory.count
    simulatedBattery.isPluggedIn = true
    simulatedBattery.level = 0.11
    waitUntil { powerReads >= readsAtHide + 3 }
    precondition(dashboardSamples == samplesAtHide && detailReads == 1)
    precondition(lastBatteryEvent?.level == 0.11 && lastBatteryEvent?.isPluggedIn == true)
    print("PASS: hidden again 0 dashboard samples / 0 battery-detail reads; AC/11% delivered")

    monitor.setDashboardVisible(true)
    precondition(dashboardSamples == samplesAtHide + 1 && detailReads == 2)
    precondition(monitor.network.download == 0 && monitor.network.upload == 0)
    precondition(monitor.disk.readRate == 0 && monitor.disk.writeRate == 0)
    precondition(monitor.processRankings.cpu.isEmpty && monitor.cpuHistory.count == cpuHistoryCount)
    precondition(monitor.netHistory.count == netHistoryCount)
    waitUntil { dashboardSamples >= samplesAtHide + 2 }
    precondition(monitor.cpuHistory.count > cpuHistoryCount && monitor.netHistory.count > netHistoryCount)
    print("PASS: reopening samples immediately; CPU/network/disk rates reset and polling resumes")
}
