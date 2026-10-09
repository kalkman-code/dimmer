import Foundation

struct KeyboardIdleLogic {
    enum Decision { case wait, apply, yield }
    private var wasIdle = false
    private var wakeAt: TimeInterval?
    private var hasSample = false

    static func restoration(idleDimmed: Bool, ownsBrightness: Bool) -> Decision {
        if idleDimmed { return .wait }
        return ownsBrightness ? .apply : .yield
    }

    mutating func update(idleDimmed: Bool, current: Double, automatic: Bool,
                         lastWritten: Double?, pendingBrightness: Double? = nil, now: TimeInterval) -> Decision {
        // A recovery journal on the first poll may be the wake baseline of a previous process.
        if !hasSample, lastWritten != nil { wakeAt = now }
        hasSample = true
        if idleDimmed {
            wasIdle = true
            wakeAt = nil
            return .wait
        }
        if wasIdle {
            wasIdle = false
            wakeAt = now
        }
        let ownsBrightness = lastWritten.map { abs(current - $0) <= RecoveryJournal.ownershipTolerance } == true
            || pendingBrightness.map { abs(current - $0) <= RecoveryJournal.ownershipTolerance } == true
        let matches = ownsBrightness && !automatic
        // The idle flag and brightness can settle on different polls. Never overwrite a mismatched
        // wake value: allow the native restore to settle, then respect a remaining user change.
        if let wakeAt, !matches, now - wakeAt < 0.5 { return .wait }
        wakeAt = nil
        return lastWritten == nil || matches ? .apply : .yield
    }
}
