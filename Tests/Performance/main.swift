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
