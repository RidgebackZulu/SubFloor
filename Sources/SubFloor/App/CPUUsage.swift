import Darwin
import Foundation

/// Process CPU time as a percentage of one core since the previous sample.
struct CPUUsage {
    private var lastCPU: Double = 0
    private var lastWall = Date()

    mutating func sample() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        let now = Date()
        defer { lastCPU = cpu; lastWall = now }
        let wall = now.timeIntervalSince(lastWall)
        return wall > 0 ? (cpu - lastCPU) / wall * 100 : 0
    }
}
