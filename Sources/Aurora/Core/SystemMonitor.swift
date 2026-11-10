//  SystemMonitor.swift
//  Aurora — 资源占用采集：CPU / 内存 / 网络 / 磁盘 / 电池 / 进程 Top
//  采集方式参考 Stats（exelban/stats）：host_processor_info、host_statistics64、getifaddrs、IOPS

import AppKit
import Combine
import IOKit.ps

@_silgen_name("proc_listallpids")
private func aurora_proc_listallpids(_ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32
@_silgen_name("proc_pid_rusage")
private func aurora_proc_pid_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("proc_pidpath")
private func aurora_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ size: UInt32) -> Int32
@_silgen_name("proc_name")
private func aurora_proc_name(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ size: UInt32) -> Int32

struct MemoryStats: Equatable {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var pressure: Double = 0

    var usage: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct NetworkStats: Equatable {
    var download: Double = 0   // bytes / s
    var upload: Double = 0
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0
}

struct DiskStats: Equatable {
    var total: UInt64 = 0
    var free: UInt64 = 0
    var readRate: Double = 0   // bytes / s
    var writeRate: Double = 0
    var usage: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
}

struct BatteryStats: Equatable {
    var level: Double = 0
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var minutesRemaining: Int = -1
    var cycleCount: Int?
    var health: Double?      // 满电容量 / 设计容量
    var condition: String?   // Normal / Service Recommended
}

struct GPUStats: Equatable {
    var available: Bool = false
    var utilization: Double = 0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var cores: Int = 0
    var name: String = ""
}

struct ProcessSample: Identifiable, Equatable {
    let id: pid_t
    var name: String
    var cpu: Double      // 百分比，可超过 100
    var memory: UInt64
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var perCore: [Double] = []
    @Published private(set) var memory = MemoryStats()
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var network = NetworkStats()
    @Published private(set) var netHistory: [(down: Double, up: Double)] = []
    @Published private(set) var disk = DiskStats()
    @Published private(set) var gpu = GPUStats()
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var neuralEngineAvailable: Bool = false
    @Published private(set) var battery: BatteryStats?
    @Published private(set) var processes: [ProcessSample] = []
    @Published private(set) var uptime: TimeInterval = 0

    private let hostPort: mach_port_t = mach_host_self()
    private var previousTicks: [UInt32] = []
    private var previousPrev: [UInt64: UInt64] = [:]   // pid -> cpu ns
    private var previousNet: (down: UInt64, up: UInt64) = (0, 0)
    private var lastSampleDate = Date()
    private var timer: Timer?
    private let historyLimit = 48
    private let coreCount = ProcessInfo.processInfo.activeProcessorCount

    init() {
        sampleOnce()
        startTimer()
    }

    deinit { timer?.invalidate() }

    func pause() {
        timer?.invalidate()
        timer = nil
    }

    func resume() {
        guard timer == nil else { return }
        sampleOnce()
        startTimer()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.sampleOnce() }
        }
    }

    func sampleOnce() {
        let now = Date()
        let elapsed = max(now.timeIntervalSince(lastSampleDate), 0.4)
        lastSampleDate = now
        uptime = ProcessInfo.processInfo.systemUptime

        let cpuSample = sampleCPU()
        cpu = cpuSample.total
        perCore = cpuSample.perCore
        push(&cpuHistory, cpuSample.total)

        memory = sampleMemory()
        push(&memoryHistory, memory.usage)

        network = sampleNetwork(elapsed: elapsed)
        netHistory.append((network.download, network.upload))
        if netHistory.count > historyLimit { netHistory.removeFirst() }

        disk = sampleDisk()
        let io = sampleDiskIO(elapsed: elapsed)
        disk.readRate = io.read
        disk.writeRate = io.write
        gpu = sampleGPU()
        push(&gpuHistory, gpu.utilization)
        neuralEngineAvailable = Self.isAppleSilicon
        battery = sampleBattery()
        processes = sampleProcesses(elapsed: elapsed)
    }

    private func push(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > historyLimit { array.removeFirst() }
    }

    // MARK: - CPU

    private func sampleCPU() -> (total: Double, perCore: [Double]) {
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0

        guard host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, []) }

        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        let cores = Int(cpuCount)
        var perCore: [Double] = []
        var usedTotal = 0.0
        var allTotal = 0.0

        for core in 0..<cores {
            let base = Int(CPU_STATE_MAX) * core
            let user = UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
            let system = UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
            let nice = UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])

            if previousTicks.count >= base + 4 {
                let userDelta = UInt64(user &- previousTicks[base])
                let systemDelta = UInt64(system &- previousTicks[base + 1])
                let idleDelta = UInt64(idle &- previousTicks[base + 2])
                let niceDelta = UInt64(nice &- previousTicks[base + 3])
                let used = userDelta + systemDelta + niceDelta
                let total = used + idleDelta
                if total > 0 {
                    perCore.append(min(1, Double(used) / Double(total)))
                    usedTotal += Double(used)
                    allTotal += Double(total)
                }
            }
        }

        previousTicks = (0..<cores).flatMap { core -> [UInt32] in
            let base = Int(CPU_STATE_MAX) * core
            return [
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ]
        }

        let total = allTotal > 0 ? usedTotal / allTotal : 0
        return (total, perCore)
    }

    // MARK: - 内存

    private func sampleMemory() -> MemoryStats {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return MemoryStats() }

        let pageSize = UInt64(vm_kernel_page_size)
        var memory = MemoryStats()
        memory.total = ProcessInfo.processInfo.physicalMemory
        memory.wired = UInt64(stats.wire_count) * pageSize
        memory.compressed = UInt64(stats.compressor_page_count) * pageSize
        memory.cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * pageSize
        let appPages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        memory.app = appPages * pageSize
        memory.used = memory.app + memory.wired + memory.compressed
        memory.pressure = memory.total > 0 ? Double(memory.used) / Double(memory.total) : 0
        return memory
    }

    // MARK: - 网络

    private func sampleNetwork(elapsed: TimeInterval) -> NetworkStats {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return NetworkStats() }
        defer { freeifaddrs(ifaddr) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var pointer = ifaddr

        while let current = pointer {
            let interface = current.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               let data = interface.ifa_data {
                let flags = Int32(interface.ifa_flags)
                let isLoopback = (flags & IFF_LOOPBACK) != 0
                if !isLoopback {
                    let stats = data.assumingMemoryBound(to: if_data.self).pointee
                    received += UInt64(stats.ifi_ibytes)
                    sent += UInt64(stats.ifi_obytes)
                }
            }
            pointer = interface.ifa_next
        }

        var network = NetworkStats()
        network.totalDown = received
        network.totalUp = sent

        if previousNet.down > 0 || previousNet.up > 0 {
            let downDelta = received >= previousNet.down ? received - previousNet.down : 0
            let upDelta = sent >= previousNet.up ? sent - previousNet.up : 0
            network.download = Double(downDelta) / elapsed
            network.upload = Double(upDelta) / elapsed
        }
        previousNet = (received, sent)
        return network
    }

    // MARK: - GPU

    private static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return value == 1
    }()

    private func sampleGPU() -> GPUStats {
        var stats = GPUStats()
        stats.name = Self.chipName
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return stats
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let raw = IORegistryEntryCreateCFProperty(
                entry,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            if let utilization = raw["Device Utilization %"] as? Int {
                stats.available = true
                stats.utilization = min(max(Double(utilization) / 100, 0), 1)
            }
            if let used = raw["In use system memory"] as? Int {
                stats.memoryUsed = UInt64(max(0, used))
            }
            if let allocated = raw["Alloc system memory"] as? Int, allocated > 0 {
                stats.memoryTotal = UInt64(allocated)
            }
            if let cores = IORegistryEntryCreateCFProperty(entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int {
                stats.cores = cores
            }
            if stats.available { break }
        }
        return stats
    }

    static var chipName: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    // MARK: - 磁盘

    private func sampleDisk() -> DiskStats {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage else {
            return DiskStats()
        }
        return DiskStats(total: UInt64(total), free: UInt64(free))
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    private static func batteryRegistry() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return dictionary
    }

    private var previousDiskBytes: (read: UInt64, write: UInt64) = (0, 0)

    /// 整盘读写速率：IOBlockStorageDriver 的 Statistics 累计值做差分（Stats 同款口径）
    private func sampleDiskIO(elapsed: TimeInterval) -> (read: Double, write: Double) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(
                entry,
                "Statistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }

        defer { previousDiskBytes = (read, write) }
        guard previousDiskBytes.read > 0 || previousDiskBytes.write > 0, elapsed > 0 else { return (0, 0) }
        let readDelta = read >= previousDiskBytes.read ? read - previousDiskBytes.read : 0
        let writeDelta = write >= previousDiskBytes.write ? write - previousDiskBytes.write : 0
        return (Double(readDelta) / elapsed, Double(writeDelta) / elapsed)
    }

    // MARK: - 电池

    private func sampleBattery() -> BatteryStats? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
        else { return nil }

        var battery = BatteryStats()
        let current = description[kIOPSCurrentCapacityKey as String] as? Int ?? 0
        let maximum = description[kIOPSMaxCapacityKey as String] as? Int ?? 100
        battery.level = maximum > 0 ? Double(current) / Double(maximum) : 0
        battery.isCharging = description[kIOPSIsChargingKey as String] as? Bool ?? false
        battery.isPluggedIn = (description[kIOPSPowerSourceStateKey as String] as? String) == kIOPSACPowerValue

        // IOPS 只给百分比，容量/循环要去 AppleSmartBattery 注册表拿（mAh）
        if let registry = Self.batteryRegistry() {
            battery.cycleCount = (registry["CycleCount"] as? NSNumber)?.intValue
            // 容量字段在 Apple Silicon 上位于 BatteryData 子字典里
            let data = registry["BatteryData"] as? [String: Any] ?? [:]
            let design = Self.number(data["DesignCapacity"] ?? registry["DesignCapacity"])
            let rawMax = Self.number(data["AppleRawMaxCapacity"] ?? registry["AppleRawMaxCapacity"])
            if design > 0, rawMax > 0 {
                battery.health = min(1, rawMax / design)
            }
            if let failure = (registry["PermanentFailureStatus"] as? NSNumber)?.intValue {
                battery.condition = failure == 0 ? "Normal" : "Service Recommended"
            }
        }

        if let minutes = description[kIOPSTimeToEmptyKey as String] as? Int, minutes > 0 {
            battery.minutesRemaining = minutes
        } else if let minutes = description[kIOPSTimeToFullChargeKey as String] as? Int, minutes > 0, battery.isCharging {
            battery.minutesRemaining = minutes
        }
        return battery
    }

    // MARK: - 进程

    private func sampleProcesses(elapsed: TimeInterval) -> [ProcessSample] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = aurora_proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }

        var samples: [ProcessSample] = []
        var nextUsage: [UInt64: UInt64] = [:]

        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { aurora_proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            guard status == 0 else { continue }

            let cpuTime = info.ri_user_time + info.ri_system_time
            nextUsage[UInt64(pid)] = cpuTime
            let previous = previousPrev[UInt64(pid)] ?? cpuTime
            let delta = cpuTime >= previous ? cpuTime - previous : 0
            let percent = Double(delta) / (elapsed * 1_000_000_000) * 100

            var buffer = [CChar](repeating: 0, count: 1024)
            let pathLength = aurora_proc_pidpath(pid, &buffer, UInt32(buffer.count))
            var name = pathLength > 0 ? (String(cString: buffer) as NSString).lastPathComponent : ""
            if name.isEmpty {
                var nameBuffer = [CChar](repeating: 0, count: 256)
                if aurora_proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0 {
                    name = String(cString: nameBuffer)
                }
            }

            if percent > 0.6 || info.ri_phys_footprint > 120 * 1024 * 1024 {
                samples.append(
                    ProcessSample(
                        id: pid,
                        name: name.isEmpty ? "pid \(pid)" : name,
                        cpu: percent,
                        memory: info.ri_phys_footprint
                    )
                )
            }
        }

        previousPrev = nextUsage
        return samples.sorted { $0.cpu > $1.cpu }.prefix(8).map { $0 }
    }
}
