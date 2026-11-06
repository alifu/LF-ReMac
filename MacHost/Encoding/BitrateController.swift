import Foundation

/// Decides the encoder's target bitrate from congestion reports. Pure value type; the clock is
/// whatever dates the caller passes in.
///
/// One stall is one cut: congestion within `cutDebounce` of the last cut is ignored (but still
/// counts as "not quiet"). After `quietBeforeRaise` without congestion the target climbs back in
/// steps of `raiseStepFraction` of the maximum, at most one step per `raiseInterval`.
struct BitrateController: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        case congested(at: Date)
        case tick(at: Date)
    }

    static let floorBitRate = 1_500_000
    static let cutFactor = 0.7
    static let cutDebounce: TimeInterval = 1
    static let quietBeforeRaise: TimeInterval = 5
    static let raiseInterval: TimeInterval = 2
    static let raiseStepFraction = 0.1

    let maxBitRate: Int
    private(set) var targetBitRate: Int
    private var lastCutAt: Date?
    private var lastCongestionAt: Date?
    private var lastRaiseAt: Date?

    init(maxBitRate: Int) {
        self.maxBitRate = maxBitRate
        self.targetBitRate = maxBitRate
    }

    private var effectiveFloor: Int { min(Self.floorBitRate, maxBitRate) }

    mutating func handle(_ event: Event) {
        switch event {
        case .congested(let date): congested(at: date)
        case .tick(let date): tick(at: date)
        }
    }

    /// Back to the maximum with no history (a new client connected).
    mutating func reset() {
        self = BitrateController(maxBitRate: maxBitRate)
    }

    private mutating func congested(at date: Date) {
        lastCongestionAt = date
        if let lastCutAt, date.timeIntervalSince(lastCutAt) < Self.cutDebounce { return }
        lastCutAt = date
        lastRaiseAt = nil
        targetBitRate = max(effectiveFloor, Int(Double(targetBitRate) * Self.cutFactor))
    }

    private mutating func tick(at date: Date) {
        guard targetBitRate < maxBitRate else { return }
        if let lastCongestionAt, date.timeIntervalSince(lastCongestionAt) < Self.quietBeforeRaise { return }
        if let lastRaiseAt, date.timeIntervalSince(lastRaiseAt) < Self.raiseInterval { return }
        lastRaiseAt = date
        targetBitRate = min(maxBitRate, targetBitRate + Int(Double(maxBitRate) * Self.raiseStepFraction))
    }
}
