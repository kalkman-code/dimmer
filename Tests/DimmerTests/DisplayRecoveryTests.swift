import XCTest
@testable import Dimmer

final class DisplayRecoveryTests: XCTestCase {
    func testOpenBrightnessChangeAfterRestoreDrivesNextClose() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        func poll(_ angle: Double) throws {
            devices.sensor.angle = angle
            _ = try devices.poll(worker, gate: gate, detector: &detector, dimsKeyboard: false)
        }
        devices.display.brightness = 0.5
        try poll(110)
        try poll(84)
        try poll(110)
        XCTAssertEqual(devices.display.brightness, 0.5, accuracy: 0.0001)
        devices.display.brightness = 0.5625
        try poll(110)
        try poll(84)
        XCTAssertEqual(devices.display.brightness, 0.28125, accuracy: 0.0001)
        try poll(110)
        XCTAssertEqual(devices.display.brightness, 0.5625, accuracy: 0.0001)
    }

    func testMidCloseChangeKeepsJournalAndCrashRecoveryOnTheOpenLevel() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        devices.display.brightness = 0.5
        _ = try devices.poll(worker, gate: gate, detector: &detector, dimsKeyboard: false)
        devices.sensor.angle = 84
        _ = try devices.poll(worker, gate: gate, detector: &detector, dimsKeyboard: false)
        devices.display.brightness = 0.4
        _ = try devices.poll(worker, gate: gate, detector: &detector, dimsKeyboard: false)
        let url = devices.directory.appendingPathComponent("display.json")
        XCTAssertEqual(try XCTUnwrap(DisplayRecoveryJournal.load(from: url)).originalBrightness, 0.5, accuracy: 0.0001)
        devices.sensor.angle = 110
        let relaunched = devices.worker()
        _ = try devices.poll(relaunched, gate: gate, detector: &detector, dimsKeyboard: false)
        XCTAssertEqual(devices.display.brightness, 0.5, accuracy: 0.0001)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testJournalSaveClampsRescaledOriginalBrightness() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let url = devices.directory.appendingPathComponent("display.json")
        for (original, expected) in [(2.25, 1.0), (-0.5, 0.0)] {
            try DisplayRecoveryJournal(originalBrightness: original, lastWritten: 0.5).save(to: url)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(try XCTUnwrap(json["originalBrightness"] as? Double), expected)
        }
    }

    func testLegacyOutOfRangeJournalRecoveryCompletesAndDimmingResumes() throws {
        for (original, expected) in [(4.5, 1.0), (-0.5, 0.0)] {
            let devices = TestHardware()
            defer { devices.cleanUp() }
            let worker = devices.worker()
            let url = devices.directory.appendingPathComponent("display.json")
            let json: [String: Double] = ["originalBrightness": original, "lastWritten": 0.5]
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            XCTAssertEqual(try XCTUnwrap(DisplayRecoveryJournal.load(from: url)).originalBrightness, expected)
            let gate = PollGeneration()
            var detector = SnapDetector()
            _ = try devices.poll(worker, gate: gate, detector: &detector, dimsKeyboard: false)
            XCTAssertEqual(devices.display.brightness, expected, accuracy: 0.0001)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            devices.sensor.angle = 84
            _ = try devices.poll(worker, gate: gate, detector: &detector, dimsKeyboard: false)
            XCTAssertEqual(devices.display.brightness, expected / 2, accuracy: 0.0001)
        }
    }

    func testMidCloseChangeGlidesBackToTheOpenLevelNearOpen() throws {
        let devices = TestHardware()
        defer { devices.cleanUp() }
        let worker = devices.worker()
        let gate = PollGeneration()
        var detector = SnapDetector()
        _ = try devices.poll(worker, gate: gate, detector: &detector, dimsKeyboard: false)
        let open = devices.display.brightness
        devices.sensor.angle = 84
        _ = try devices.poll(worker, gate: gate, detector: &detector, dimsKeyboard: false)
        devices.display.brightness = 0.9
        _ = try devices.poll(worker, gate: gate, detector: &detector, dimsKeyboard: false)
        let url = devices.directory.appendingPathComponent("display.json")
        XCTAssertEqual(try XCTUnwrap(DisplayRecoveryJournal.load(from: url)).originalBrightness, open, accuracy: 0.0001)
        devices.sensor.angle = 99
        // Let the angle filter reach its stationary value before counting writes.
        for _ in 0..<100 {
            _ = try devices.poll(worker, gate: gate, detector: &detector, dimsKeyboard: false)
        }
        var writes = 0
        devices.display.onWrite = { _ in writes += 1 }
        for _ in 0..<10 {
            _ = try devices.poll(worker, gate: gate, detector: &detector, dimsKeyboard: false)
        }
        XCTAssertEqual(writes, 0)
        XCTAssertLessThan(abs(devices.display.brightness - open), abs(0.9 - open))
        devices.sensor.angle = 110
        _ = try devices.poll(worker, gate: gate, detector: &detector, dimsKeyboard: false)
        XCTAssertEqual(devices.display.brightness, open, accuracy: 0.0001)
    }

    func testScreenRangeChangeDropsMidCloseAdjustmentAndKeepsDimming() throws {
        let range = DimRange(lowAngle: 68, lowLevel: 0, highAngle: 100, highLevel: 0.9)
        let cases: [(range: DimRange, targets: [Double])] = [
            (DimRange(lowAngle: 68, lowLevel: 0, highAngle: 100, highLevel: 0), [0, 0]),
            (DimRange(lowAngle: 88, lowLevel: 0, highAngle: 100, highLevel: 1), [0, 0]),
            (DimRange(lowAngle: 68, lowLevel: 0, highAngle: 100, highLevel: 0.5), [0.140625, 0.09375]),
        ]
        for item in cases {
            var logic = DisplayDimmingLogic()
            _ = logic.update(angle: 110, current: 0.75, range: range)
            _ = logic.update(angle: 84, current: 0.75, range: range)
            logic.markWritten(0.3375)
            XCTAssertEqual(logic.update(angle: 84, current: 0.4, range: range), .dim(target: 0.4, override: true))
            logic.markWritten(0.4)
            var current = 0.4
            for (angle, expected) in zip([80.0, 76.0], item.targets) {
                guard case .dim(let target, _) = logic.update(angle: angle, current: current, range: item.range) else {
                    XCTFail("Expected dimming after a screen-range change")
                    continue
                }
                XCTAssertTrue(target.isFinite)
                XCTAssertTrue((0...1).contains(target))
                XCTAssertEqual(target, expected, accuracy: 0.0001)
                logic.markWritten(target)
                current = target
            }
            XCTAssertTrue(logic.isDimming)
            XCTAssertEqual(try XCTUnwrap(logic.prepareRestore()), 0.75)
        }
    }

    func testNearShutBrightnessStepDoesNotAmplifyOpenLevel() throws {
        let range = DimRange.screenDefault
        var logic = DisplayDimmingLogic()
        _ = logic.update(angle: 110, current: 0.5, range: range)
        guard case .dim(let target, _) = logic.update(angle: 70, current: 0.5, range: range) else {
            return XCTFail("Expected dimming")
        }
        logic.markWritten(target)
        _ = logic.update(angle: 70, current: target + 0.0625, range: range)
        XCTAssertEqual(try XCTUnwrap(logic.prepareRestore()), 0.5)
    }
}
