import Foundation

public enum TransferPhase: String, Sendable {
    case downloading = "Downloading"
    case recoveringSlowRange = "Recovering slow final chunk"
    case assembling = "Finishing file"
}

public struct TailRecoveryPolicy: Sendable {
    public let enabled: Bool
    public let gracePeriod: TimeInterval
    public init(enabled: Bool = true, gracePeriod: TimeInterval = 2) {
        self.enabled = enabled
        self.gracePeriod = gracePeriod.isFinite ? min(60, max(0.05, gracePeriod)) : 2
    }
}
