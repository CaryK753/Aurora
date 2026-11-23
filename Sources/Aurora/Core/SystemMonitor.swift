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

struct MemoryStats: Equatable, Sendable {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var pressure: Double = 0

    var usage: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct NetworkStats: Equatable, Sendable {
    var download: Double = 0   // bytes / s
    var upload: Double = 0
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0
}

struct DiskCapacity: Sendable {
    let total: UInt64
    let free: UInt64
}

struct DiskStats: Equatable, Sendable {
    var total: UInt64 = 0
    var free: UInt64 = 0
    var readRate: Double = 0   // bytes / s
    var writeRate: Double = 0
    var usage: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
}

struct BatteryStats: Equatable, Sendable {
    var level: Double = 0
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var minutesRemaining: Int = -1
    var cycleCount: Int?
    var health: Double?      // 满电容量 / 设计容量
    var condition: String?   // Normal / Service Recommended
}

struct GPUStats: Equatable, Sendable {
    var available: Bool = false
    var utilization: Double = 0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var cores: Int = 0
    var name: String = ""
}

struct ProcessSample: Identifiable, Equatable, Sendable {
    let id: pid_t
    var name: String
    var cpu: Double      // 百分比，可超过 100
    var memory: UInt64
}

struct ProcessRankings: Equatable, Sendable {
    var cpu: [ProcessSample] = []
    var memory: [ProcessSample] = []

    init() {}

    init(samples: [ProcessSample], limit: Int = 8, nameForPID: (pid_t) -> String) {
        let cpuTop = samples.filter { $0.cpu > 0.6 }.sorted {
            $0.cpu == $1.cpu ? $0.id < $1.id : $0.cpu > $1.cpu
        }.prefix(limit)
        let memoryTop = samples.filter { $0.memory > 0 }.sorted {
            $0.memory == $1.memory ? $0.id < $1.id : $0.memory > $1.memory
        }.prefix(limit)

        // Resolve executable names only once per PID, and only for rows that will be published.
        var names: [pid_t: String] = [:]
        func withName(_ sample: ProcessSample) -> ProcessSample {
            var row = sample
            if let name = names[row.id] {
                row.name = name
            } else {
                row.name = nameForPID(row.id)
                names[row.id] = row.name
            }
            return row
        }
        cpu = cpuTop.map(withName)
        memory = memoryTop.map(withName)
    }
}

struct ProcessCPUCounters {
    let ticks: UInt64
    let startedAt: UInt64

    static let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return 1 }
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    func percent(since previous: Self?, elapsed: TimeInterval) -> Double {
        guard let previous, startedAt == previous.startedAt, ticks >= previous.ticks, elapsed > 0 else {
            return 0
        }
        return Double(ticks - previous.ticks) * Self.nanosecondsPerTick / (elapsed * 1_000_000_000) * 100
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    struct Dashboard {
        var cpu: Double = 0
        var cpuHistory: [Double] = []
        var perCore: [Double] = []
        var memory = MemoryStats()
        var memoryHistory: [Double] = []
        var network = NetworkStats()
        var netHistory: [(down: Double, up: Double)] = []
        var disk = DiskStats()
        var gpu = GPUStats()
        var gpuHistory: [Double] = []
        var neuralEngineAvailable: Bool = false
        var processRankings = ProcessRankings()
        var uptime: TimeInterval = 0
    }

    @Published private(set) var dashboard = Dashboard()
    @Published private(set) var battery: BatteryStats?
    var cpu: Double { dashboard.cpu }
    var cpuHistory: [Double] { dashboard.cpuHistory }
    var perCore: [Double] { dashboard.perCore }
    var memory: MemoryStats { dashboard.memory }
    var memoryHistory: [Double] { dashboard.memoryHistory }
    var network: NetworkStats { dashboard.network }
    var netHistory: [(down: Double, up: Double)] { dashboard.netHistory }
    var disk: DiskStats { dashboard.disk }
    var gpu: GPUStats { dashboard.gpu }
    var gpuHistory: [Double] { dashboard.gpuHistory }
    var neuralEngineAvailable: Bool { dashboard.neuralEngineAvailable }
    var processRankings: ProcessRankings { dashboard.processRankings }
    var uptime: TimeInterval { dashboard.uptime }

    private let sampler: BackgroundSnapshot<MonitorCollector.Request, MonitorCollector.Reading>
    private let diskCapacityWorker: BackgroundSnapshot<Void, DiskCapacity?>
    private let pollInterval: TimeInterval
    private let diskCapacityInterval: TimeInterval
    private var lastDiskCapacityRequest: TimeInterval?
    private var diskCapacity: DiskCapacity?
    private var lastSampleTime: TimeInterval?
    private var timer: Timer?
    private var dashboardVisible: Bool
    private var session: UInt64 = 0
    private var forceDashboard = false
    private let historyLimit = 48

    init(dashboardVisible: Bool = true, pollInterval: TimeInterval = 1.2,
         readPowerState: @escaping @Sendable () -> BatteryStats? = { MonitorCollector.readPowerState() },
         readBatteryDetails: @escaping @Sendable (inout BatteryStats) -> Void = { MonitorCollector.readBatteryDetails(&$0) },
         diskCapacityInterval: TimeInterval = 30,
         readDiskCapacity: @escaping @Sendable () -> DiskCapacity? = { MonitorCollector.readDiskCapacity() }) {
        self.dashboardVisible = dashboardVisible
        self.pollInterval = pollInterval
        self.diskCapacityInterval = diskCapacityInterval
        let collector = MonitorCollector(readPowerState: readPowerState, readBatteryDetails: readBatteryDetails)
        sampler = BackgroundSnapshot(label: "aurora.dashboard.collector", read: { collector.read($0) })
        diskCapacityWorker = BackgroundSnapshot(label: "aurora.disk.capacity", read: readDiskCapacity)
        enqueue(sampleDashboard: dashboardVisible)
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = pollInterval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }

    func setDashboardVisible(_ visible: Bool) {
        guard dashboardVisible != visible else { return }
        dashboardVisible = visible
        session &+= 1
        lastSampleTime = nil
        forceDashboard = visible
        if visible { sampleOnce() }
    }

    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        enqueue(sampleDashboard: dashboardVisible && (lastSampleTime.map { now - $0 >= pollInterval / 2 } ?? true))
    }

    func sampleOnce() {
        guard dashboardVisible else { return }
        forceDashboard = true
        enqueue(sampleDashboard: true)
    }

    private func enqueue(sampleDashboard: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let request = MonitorCollector.Request(now: now, session: session, dashboard: sampleDashboard)
        if sampler.request(request, { [weak self] reading in
            guard let self else { return }
            if self.session == request.session {
                if self.battery != reading.battery { self.battery = reading.battery }
                if self.dashboardVisible, let latest = reading.dashboard { self.apply(latest) }
            }
            if self.forceDashboard { self.enqueue(sampleDashboard: true) }
        }) {
            if sampleDashboard {
                forceDashboard = false
                lastSampleTime = now
                refreshDiskCapacityIfNeeded(at: now)
            }
        }
    }

    private func apply(_ sample: MonitorCollector.DashboardReading) {
        var next = dashboard
        next.cpu = sample.cpu.total
        next.perCore = sample.cpu.perCore
        if sample.hasPrevious { push(&next.cpuHistory, sample.cpu.total) }
        next.memory = sample.memory
        push(&next.memoryHistory, sample.memory.usage)
        next.network = sample.network
        if sample.hasPrevious { push(&next.netHistory, (sample.network.download, sample.network.upload)) }
        next.disk = makeDisk(read: sample.diskIO.read, write: sample.diskIO.write)
        next.gpu = sample.gpu
        push(&next.gpuHistory, sample.gpu.utilization)
        next.neuralEngineAvailable = sample.neuralEngineAvailable
        next.processRankings = sample.processRankings
        next.uptime = sample.uptime
        dashboard = next
    }

    private func push<Value>(_ array: inout [Value], _ value: Value) {
        array.append(value)
        if array.count > historyLimit { array.removeFirst() }
    }

    private func makeDisk(read: Double, write: Double) -> DiskStats {
        let total = diskCapacity?.total ?? 0
        return DiskStats(total: total, free: min(diskCapacity?.free ?? 0, total), readRate: read, writeRate: write)
    }

    private func refreshDiskCapacityIfNeeded(at now: TimeInterval) {
        if let lastDiskCapacityRequest, now - lastDiskCapacityRequest < diskCapacityInterval { return }
        if diskCapacityWorker.request({ [weak self] capacity in
            guard let self, let capacity else { return }
            self.diskCapacity = capacity
            guard self.dashboardVisible else { return }
            let disk = self.makeDisk(read: self.disk.readRate, write: self.disk.writeRate)
            if disk != self.dashboard.disk { self.dashboard.disk = disk }
        }) {
            lastDiskCapacityRequest = now
        }
    }

    static var chipName: String { MonitorCollector.chipName }
}

/// Mutable counters are exclusively owned by the sampler's serial utility queue.
private final class MonitorCollector: @unchecked Sendable {
    struct Request: Sendable {
        let now: TimeInterval
        let session: UInt64
        let dashboard: Bool
    }

    struct DashboardReading: Sendable {
        let uptime: TimeInterval
        let hasPrevious: Bool
        let cpu: (total: Double, perCore: [Double])
        let memory: MemoryStats
        let network: NetworkStats
        let diskIO: (read: Double, write: Double)
        let gpu: GPUStats
        let neuralEngineAvailable: Bool
        let processRankings: ProcessRankings
    }

    struct Reading: Sendable {
        let battery: BatteryStats?
        let dashboard: DashboardReading?
    }

    private let hostPort = mach_host_self()
    private let readPowerState: @Sendable () -> BatteryStats?
    private let readBatteryDetails: @Sendable (inout BatteryStats) -> Void
    private var battery: BatteryStats?
    private var lastBatteryDetailsTime: TimeInterval?
    private var previousTicks: [UInt32] = []
    private var previousUsage: [pid_t: ProcessCPUCounters] = [:]
    private var previousNet: (down: UInt64, up: UInt64)?
    private var lastSampleTime: TimeInterval?
    private var session: UInt64?

    init(readPowerState: @escaping @Sendable () -> BatteryStats?,
         readBatteryDetails: @escaping @Sendable (inout BatteryStats) -> Void) {
        self.readPowerState = readPowerState
        self.readBatteryDetails = readBatteryDetails
    }

    deinit { mach_port_deallocate(mach_task_self_, hostPort) }

    func read(_ request: Request) -> Reading {
        if session != request.session {
            session = request.session
            lastSampleTime = nil
            previousTicks.removeAll()
            previousUsage.removeAll()
            previousNet = nil
            previousDiskBytes = nil
            lastBatteryDetailsTime = nil
        }
        refreshBattery(at: request.now, includeDetails: request.dashboard)
        guard request.dashboard else { return Reading(battery: battery, dashboard: nil) }
        let elapsed = lastSampleTime.map { max(request.now - $0, 0.001) }
        lastSampleTime = request.now
        return Reading(battery: battery, dashboard: DashboardReading(
            uptime: request.now, hasPrevious: elapsed != nil, cpu: sampleCPU(), memory: sampleMemory(),
            network: sampleNetwork(elapsed: elapsed), diskIO: sampleDiskIO(elapsed: elapsed),
            gpu: sampleGPU(), neuralEngineAvailable: Self.isAppleSilicon,
            processRankings: sampleProcesses(elapsed: elapsed ?? 0)
        ))
    }

    private func refreshBattery(at now: TimeInterval, includeDetails: Bool) {
        guard var current = readPowerState() else {
            battery = nil
            lastBatteryDetailsTime = nil
            return
        }
        if includeDetails, lastBatteryDetailsTime.map({ now - $0 >= 60 }) ?? true {
            readBatteryDetails(&current)
            lastBatteryDetailsTime = now
        } else {
            current.cycleCount = battery?.cycleCount
            current.health = battery?.health
            current.condition = battery?.condition
        }
        battery = current
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
        let appPages = UInt64(stats.internal_page_count - min(stats.internal_page_count, stats.purgeable_count))
        memory.app = appPages * pageSize
        memory.used = memory.app + memory.wired + memory.compressed
        memory.pressure = memory.total > 0 ? Double(memory.used) / Double(memory.total) : 0
        return memory
    }

    // MARK: - 网络

    private func sampleNetwork(elapsed: TimeInterval?) -> NetworkStats {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            previousNet = nil
            return NetworkStats()
        }
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

        if let elapsed, let previousNet {
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

    static let chipName: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()

    // MARK: - 磁盘

    static func readDiskCapacity() -> DiskCapacity? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacityForImportantUsage,
              total > 0, free >= 0 else { return nil }
        return DiskCapacity(total: UInt64(total), free: UInt64(free))
    }

    nonisolated private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    nonisolated private static func batteryRegistry() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return dictionary
    }

    private var previousDiskBytes: (read: UInt64, write: UInt64)?

    /// 整盘读写速率：IOBlockStorageDriver 的 Statistics 累计值做差分（Stats 同款口径）
    private func sampleDiskIO(elapsed: TimeInterval?) -> (read: Double, write: Double) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            previousDiskBytes = nil
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
        guard let previousDiskBytes, let elapsed else { return (0, 0) }
        let readDelta = read >= previousDiskBytes.read ? read - previousDiskBytes.read : 0
        let writeDelta = write >= previousDiskBytes.write ? write - previousDiskBytes.write : 0
        return (Double(readDelta) / elapsed, Double(writeDelta) / elapsed)
    }

    // MARK: - 电池

    static func readPowerState() -> BatteryStats? {
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

        if let minutes = description[kIOPSTimeToEmptyKey as String] as? Int, minutes > 0 {
            battery.minutesRemaining = minutes
        } else if let minutes = description[kIOPSTimeToFullChargeKey as String] as? Int, minutes > 0, battery.isCharging {
            battery.minutesRemaining = minutes
        }
        return battery
    }

    static func readBatteryDetails(_ battery: inout BatteryStats) {
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
    }

    // MARK: - 进程

    private func sampleProcesses(elapsed: TimeInterval) -> ProcessRankings {
        let estimatedCount = aurora_proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: max(256, Int(estimatedCount) + 64))
        let count = pids.withUnsafeMutableBytes {
            aurora_proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard count > 0 else {
            previousUsage.removeAll()
            return ProcessRankings()
        }

        var samples: [ProcessSample] = []
        var nextUsage: [pid_t: ProcessCPUCounters] = [:]
        samples.reserveCapacity(Int(count))
        nextUsage.reserveCapacity(Int(count))

        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { aurora_proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            guard status == 0 else { continue }

            let counters = ProcessCPUCounters(
                ticks: info.ri_user_time + info.ri_system_time,
                startedAt: info.ri_proc_start_abstime
            )
            nextUsage[pid] = counters
            samples.append(ProcessSample(id: pid, name: "",
                                         cpu: counters.percent(since: previousUsage[pid], elapsed: elapsed),
                                         memory: info.ri_phys_footprint))
        }

        previousUsage = nextUsage
        return ProcessRankings(samples: samples, nameForPID: Self.processName)
    }

    private static func processName(for pid: pid_t) -> String {
        var path = [CChar](repeating: 0, count: 1024)
        if aurora_proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let name = (String(cString: path) as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        var name = [CChar](repeating: 0, count: 256)
        if aurora_proc_name(pid, &name, UInt32(name.count)) > 0 {
            return String(cString: name)
        }
        return "pid \(pid)"
    }
}
