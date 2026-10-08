import Foundation
import IOKit.hid

enum SensorError: LocalizedError {
    case unavailable
    case openFailed(IOReturn)
    case readFailed(IOReturn)
    case malformedReport

    var errorDescription: String? {
        switch self {
        case .unavailable: "Built-in lid angle sensor is unavailable."
        case .openFailed(let code): "Could not open the lid angle sensor (\(code))."
        case .readFailed(let code): "Could not read the lid angle sensor (\(code))."
        case .malformedReport: "The lid angle sensor returned an invalid reading."
        }
    }
}

final class LidAngleSensor {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    func open() throws {
        close()
        let newManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x8104,
            kIOHIDPrimaryUsagePageKey as String: 0x20,
            kIOHIDPrimaryUsageKey as String: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(newManager, matching as CFDictionary)
        guard IOHIDManagerOpen(newManager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(newManager) as? Set<IOHIDDevice>,
              let found = devices.first else { throw SensorError.unavailable }
        let result = IOHIDDeviceOpen(found, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw SensorError.openFailed(result) }
        manager = newManager
        device = found
    }

    func readAngleDegrees() throws -> Double {
        guard let device else { throw SensorError.unavailable }
        var report = [UInt8](repeating: 0, count: 64)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        guard result == kIOReturnSuccess else { throw SensorError.readFailed(result) }
        guard length >= 3, report[0] == 1 else { throw SensorError.malformedReport }
        let degrees = UInt16(report[1]) | (UInt16(report[2]) << 8)
        guard degrees <= 140 else { throw SensorError.malformedReport }
        return Double(degrees)
    }

    func close() {
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        manager = nil
    }
}
