import XCTest
@testable import Dimmer

final class FeatureLogicTests: XCTestCase {
    func testKeepAwakeDeadlineUsesSelectedDuration() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-08T14:00:00Z"))
        XCTAssertEqual(
            AwakeSchedule.deadline(for: .fifteenMinutes, startedAt: start, untilTime: start),
            start.addingTimeInterval(15 * 60)
        )
        XCTAssertNil(AwakeSchedule.deadline(for: .off, startedAt: start, untilTime: start))
        XCTAssertNil(AwakeSchedule.deadline(for: .indefinitely, startedAt: start, untilTime: start))
    }

    func testKeepAwakeUntilTimeRollsToTomorrowWhenThatTimeHasPassed() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-08T18:00:00Z"))
        let untilTime = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-08T17:00:00Z"))

        XCTAssertEqual(
            AwakeSchedule.deadline(for: .untilTime, startedAt: start, untilTime: untilTime, calendar: calendar),
            try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-09T17:00:00Z"))
        )
    }

    // Feeds 10 Hz samples, the app's poll rate, and returns the detector's verdict for each.
    private func run(_ angles: [Double], settings: SnapSettings = SnapSettings(), from start: Double = 0,
                     detector: inout SnapDetector) -> [SnapDetector.Veil] {
        angles.enumerated().map { detector.observe(LidSample(angle: $1, time: start + Double($0) / 10), settings: settings) }
    }

    func testSnapFromAboveZoneLocksUntilReset() {
        var detector = SnapDetector()
        XCTAssertEqual(run([110, 110, 95, 80], detector: &detector).last, .snapped)
        XCTAssertEqual(detector.observe(LidSample(angle: 110, time: 1), settings: SnapSettings()), .snapped)
        detector.reset()
        XCTAssertEqual(detector.observe(LidSample(angle: 110, time: 2), settings: SnapSettings()), SnapDetector.Veil.none)
    }

    func testPushBackClearsFromLowestPostSnapAngle() {
        var detector = SnapDetector()
        XCTAssertEqual(run([110, 110, 100, 90], detector: &detector).last, .snapped)
        XCTAssertEqual(detector.lowestAngle, 90)
        XCTAssertFalse(detector.pushedBack(78, settings: SnapSettings()))
        XCTAssertEqual(detector.lowestAngle, 78)
        XCTAssertFalse(detector.pushedBack(79, settings: SnapSettings()))
        XCTAssertFalse(detector.pushedBack(80, settings: SnapSettings()))
        XCTAssertTrue(detector.pushedBack(81, settings: SnapSettings()))
    }

    // Toby's misses on 08-10-2026: flicks that began inside the zone (94°→87° at 69°/s, 78°→67° at
    // 55°/s with the zone at 50–101°) never fired, because a snap had to start above the zone.
    func testFlickStartingInsideTheZoneSnaps() {
        var zone = SnapSettings()
        zone.zoneLow = 50
        zone.zoneHigh = 101
        var detector = SnapDetector()
        XCTAssertEqual(run([94, 94, 87], settings: zone, detector: &detector).last, .snapped)
    }

    func testSlowerFlickFadesInPartlyThenOut() {
        var zone = SnapSettings()
        zone.zoneLow = 50
        zone.zoneHigh = 101
        var detector = SnapDetector()
        // 104°→91° over 0.6 s is about 21°/s: short of a snap at 60°/s, but a flick.
        let verdicts = run([104, 102, 100, 97, 95, 93, 91, 91, 91, 91, 91, 91], settings: zone, detector: &detector)
        XCTAssertTrue(verdicts.contains { if case .partial = $0 { return true } else { return false } })
        XCTAssertFalse(verdicts.contains(.snapped))
        XCTAssertEqual(verdicts.last, SnapDetector.Veil.none, "once the lid stops, the partial veil is released")
    }

    func testTypingWobbleNeverShowsTheVeil() {
        var detector = SnapDetector()
        let wobble = (0..<60).map { $0 % 2 == 0 ? 88.0 : 87.0 }
        XCTAssertEqual(Set(run(wobble, detector: &detector)), [.none])
    }

    func testSlowCloseNeverSnaps() {
        var detector = SnapDetector()
        let close = stride(from: 110.0, through: 70, by: -1.5).map { $0 }   // 15°/s at 10 Hz
        XCTAssertFalse(run(close, detector: &detector).contains(.snapped))
    }

    func testFastPassThatLandsBelowTheZoneDoesNotSnap() {
        var detector = SnapDetector()
        XCTAssertFalse(run([110, 60, 60], detector: &detector).contains(.snapped))
    }

    func testCustomZoneAndSnapSize() {
        var custom = SnapSettings()
        custom.zoneLow = 60
        custom.zoneHigh = 70
        custom.snapDegrees = 8
        var detector = SnapDetector()
        XCTAssertEqual(run([100, 100, 68], settings: custom, detector: &detector).last, .snapped)
        var small = SnapDetector()
        XCTAssertNotEqual(run([72, 72, 66], settings: custom, detector: &small).last, .snapped, "6° is under the 8° snap")
    }

    // Whatever the lid does, the veil level the overlay draws from stays a finite fraction.
    func testVeilLevelsStayFiniteUnderRandomLidMovement() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var settings = SnapSettings(zoneLow: Double.random(in: 0...120, using: &generator), zoneHigh: 0,
                                        snapDegrees: Double.random(in: 1...40, using: &generator),
                                        minimumSpeed: Double.random(in: 10...300, using: &generator))
            settings.zoneHigh = settings.zoneLow + Double.random(in: 2...30, using: &generator)
            settings = settings.clamped(maximum: LidAxis.maximum)
            var detector = SnapDetector()
            var angle = Double.random(in: 0...130, using: &generator)
            for tick in 0..<80 {
                angle = min(130, max(0, angle + Double.random(in: -25...25, using: &generator)))
                switch detector.observe(LidSample(angle: angle, time: Double(tick) / 10), settings: settings) {
                case .partial(let level):
                    XCTAssertTrue(level.isFinite && level >= 0 && level <= 1, "level \(level)")
                case .snapped:
                    detector.reset()
                case .none:
                    break
                }
            }
        }
    }

    func testLiftHysteresis() {
        let detector = SnapDetector()
        XCTAssertFalse(detector.liftedAbove(100, settings: SnapSettings()))
        XCTAssertTrue(detector.liftedAbove(101, settings: SnapSettings()))
    }

    func testInputGraceRequiresPostSnapEvent() {
        XCTAssertFalse(SnapDetector.inputArrived(idleSeconds: 1, now: 10.3, blurredAt: 10))
        XCTAssertTrue(SnapDetector.inputArrived(idleSeconds: 0.2, now: 10.7, blurredAt: 10))
    }

    @MainActor
    func testInputClearsPartialVeilWithoutFurtherLidSamplesOrGrace() async throws {
        for kind in ["key", "pointer move", "scroll", "click"] {
            let suiteName = UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let overlay = RecordingPrivacyBlurOverlay()
            let inputChecked = expectation(description: "Checks \(kind) while lid polling is stopped")
            let cleared = expectation(description: "Clears partial veil on \(kind)")
            var eventTime = 99.0
            var checkedOldInput = false
            var reportedClear = false
            let features = DimmerFeatures(defaults: defaults, overlay: overlay, lastInput: {
                if !checkedOldInput {
                    checkedOldInput = true
                    inputChecked.fulfill()
                }
                return (seconds: 100.31 - eventTime, kind: kind)
            }, uptime: { 100.31 })
            defer { features.stop() }
            features.privacyEnabled = true
            features.snap = SnapSettings(zoneLow: 50, zoneHigh: 101)
            overlay.onUpdate = { [weak overlay] visible in
                if !visible && overlay?.hasShownVeil == true && !reportedClear {
                    reportedClear = true
                    cleared.fulfill()
                }
            }
            for (index, angle) in [104.0, 102, 99, 96].enumerated() {
                features.update(sample: LidSample(angle: angle, time: 100 + Double(index) / 10))
            }

            await fulfillment(of: [inputChecked], timeout: 2)
            XCTAssertTrue(overlay.visible, "Input before the partial veil must not clear it")
            XCTAssertFalse(features.privacyBlurActive, "The flick must remain a partial veil")
            eventTime = 100.21
            await fulfillment(of: [cleared], timeout: 2)
            XCTAssertFalse(overlay.visible)
            XCTAssertEqual(overlay.strength, 0, "Input clears immediately, without a fade")
        }
    }

    func testSnapSettingsClampingKeepsZoneInsideAxisAndTwoDegreesWide() {
        var settings = SnapSettings(zoneLow: 200, zoneHigh: -10, snapDegrees: 100, minimumSpeed: 1, blurStrength: 2)
        settings = settings.clamped(maximum: LidAxis.maximum)
        XCTAssertEqual(settings.zoneLow, 128)
        XCTAssertEqual(settings.zoneHigh, 130)
        XCTAssertGreaterThanOrEqual(settings.zoneHigh - settings.zoneLow, 2)
        XCTAssertEqual(settings.snapDegrees, 40)
        XCTAssertEqual(settings.minimumSpeed, 10)
        XCTAssertEqual(settings.blurStrength, 1)
        XCTAssertEqual(SnapSettings(smoke: 3).clamped(maximum: LidAxis.maximum).smoke, 1)
        XCTAssertEqual(SnapSettings(smoke: -1).clamped(maximum: LidAxis.maximum).smoke, 0)
        XCTAssertEqual(SnapSettings(clearSeconds: -1).clamped(maximum: LidAxis.maximum).clearSeconds, 0)
        XCTAssertEqual(SnapSettings(clearSeconds: 1).clamped(maximum: LidAxis.maximum).clearSeconds, 0.6)
    }

    func testSnapSettingsSavedBeforeTintKeepTheirValues() throws {
        // Exactly what Toby's test build stored on 08-10-2026, before the tint existed.
        let saved = #"{"blurStrength":0.44,"zoneLow":70,"zoneHigh":91,"snapDegrees":8,"minimumSpeed":90}"#
        let settings = try JSONDecoder().decode(SnapSettings.self, from: Data(saved.utf8))
        XCTAssertEqual(settings, SnapSettings(zoneLow: 70, zoneHigh: 91, snapDegrees: 8, minimumSpeed: 90, blurStrength: 0.44, smoke: 0, clearSeconds: 0.08))
        let roundTrip = try JSONDecoder().decode(SnapSettings.self, from: JSONEncoder().encode(SnapSettings(smoke: 0.6)))
        XCTAssertEqual(roundTrip.smoke, 0.6)
    }

    func testGoDarkScalesLevelsToOff() {
        XCTAssertEqual(GoDark.level(0.8, darkness: 0), 0.8)
        XCTAssertEqual(GoDark.level(0.8, darkness: 0.5), 0.4, accuracy: 0.0001)
        XCTAssertEqual(GoDark.level(0.8, darkness: 1), 0)
        XCTAssertEqual(GoDark.level(0.8, darkness: 3), 0)
    }

    func testGoDarkIgnoresTheChoosingClickThenWakesOnInputOrLidMove() {
        // Input 0.5 s after going dark (inside the grace) does not wake it; input after 1.5 s does.
        XCTAssertFalse(GoDark.shouldWake(idleSeconds: 0, now: 100.5, darkAt: 100, angle: 110, startAngle: 110))
        XCTAssertTrue(GoDark.shouldWake(idleSeconds: 0, now: 101.5, darkAt: 100, angle: 110, startAngle: 110))
        XCTAssertFalse(GoDark.shouldWake(idleSeconds: 30, now: 105, darkAt: 100, angle: 112, startAngle: 110))
        XCTAssertTrue(GoDark.shouldWake(idleSeconds: 30, now: 105, darkAt: 100, angle: 107, startAngle: 110))
    }

    func testGoDarkGammaReachesBlackOnlyAtFullDarkness() {
        let range = DimRange.keyboardDefault
        XCTAssertEqual(DisplayGammaFade.factor(angle: 110, range: range, darkness: 0), 1)
        XCTAssertEqual(DisplayGammaFade.factor(angle: 110, range: range, darkness: 0.5), 1)
        XCTAssertEqual(DisplayGammaFade.factor(angle: 110, range: range, darkness: 1), 0)
        let midway = DisplayGammaFade.factor(angle: 110, range: range, darkness: 0.8)
        XCTAssertGreaterThan(midway, 0)
        XCTAssertLessThan(midway, 1)
    }

    func testGoDarkWithTheLidOpenCapturesAndDimsTheScreen() {
        var logic = DisplayDimmingLogic()
        guard case .dim(let half, _) = logic.update(angle: 110, current: 0.6, range: .screenDefault, darkness: 0.5) else {
            return XCTFail("Go dark should dim even above the screen range")
        }
        XCTAssertEqual(logic.baseline, 0.6)
        XCTAssertEqual(half, 0.3, accuracy: 0.0001)
        guard case .dim(let off, _) = logic.update(angle: 110, current: 0.3, range: .screenDefault, darkness: 1) else {
            return XCTFail("Expected full darkness to dim")
        }
        XCTAssertEqual(off, 0)
        XCTAssertEqual(logic.update(angle: 110, current: 0, range: .screenDefault, darkness: 0), .idle)
        XCTAssertEqual(logic.prepareRestore(), 0.6)
    }

    func testLegacyMigrationKeepsASingleMovedSlider() {
        XCTAssertNil(DimRange.migrated(offAt: nil, fullAt: nil))
        XCTAssertEqual(DimRange.migrated(offAt: 50, fullAt: nil), DimRange(lowAngle: 50, lowLevel: 0, highAngle: 85, highLevel: 1))
        XCTAssertEqual(DimRange.migrated(offAt: nil, fullAt: 100), DimRange(lowAngle: 30, lowLevel: 0, highAngle: 100, highLevel: 1))
    }
}

@MainActor
private final class RecordingPrivacyBlurOverlay: PrivacyBlurOverlay {
    private(set) var visible = false
    private(set) var strength = 0.0
    private(set) var hasShownVeil = false
    var onUpdate: ((Bool) -> Void)?

    func update(privacyBlur: Bool, strength: Double, smoke: Double, reduceTransparency: Bool) {
        visible = privacyBlur
        self.strength = strength
        hasShownVeil = hasShownVeil || privacyBlur
        onUpdate?(privacyBlur)
    }

    func describe() -> String { "recording overlay" }
    func stop() {}
}
