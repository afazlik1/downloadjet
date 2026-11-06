import Foundation

public struct DownloadSpeedSample: Identifiable, Sendable {
    public var id: TimeInterval { time }
    public let time: TimeInterval
    public let bytesPerSecond: Double
}

/// Samples received payload bytes using elapsed monotonic time, independently of
/// cached progress, range retries, and final file assembly.
public struct DownloadSpeedHistory: Sendable {
    public static let interval: TimeInterval = 0.20
    public static let duration: TimeInterval = 30
    public static let sampleLimit = Int((duration / interval).rounded()) + 1
    public private(set) var samples: [DownloadSpeedSample]
    public private(set) var speeds: [UUID: Double] = [:]
    public private(set) var totalSpeed: Double = 0
    private var pending: [UUID: Double] = [:]
    private var previousTime: TimeInterval

    public init(now: TimeInterval) {
        previousTime = now
        samples = (0..<Self.sampleLimit).map {
            DownloadSpeedSample(time: now - Self.duration + Double($0) * Self.interval, bytesPerSecond: 0)
        }
    }
    public mutating func record(_ bytes: Int64, for id: UUID) {
        guard bytes > 0 else { return }
        pending[id, default: 0] += Double(bytes)
    }
    public mutating func sample(at now: TimeInterval) {
        let elapsed = now - previousTime
        guard elapsed > 0 else { return }
        speeds = pending.mapValues { $0 / elapsed }
        totalSpeed = speeds.values.reduce(0, +)
        pending.removeAll(keepingCapacity: true)
        previousTime = now
        samples.removeAll { $0.time < now - Self.duration }
        if samples.isEmpty {
            samples.append(DownloadSpeedSample(time: now - Self.duration, bytesPerSecond: 0))
        }
        samples.append(DownloadSpeedSample(time: now, bytesPerSecond: totalSpeed))
        // Bound memory even if a caller samples more frequently than the UI timer.
        if samples.count > Self.sampleLimit { samples.removeFirst(samples.count - Self.sampleLimit) }
    }
}
