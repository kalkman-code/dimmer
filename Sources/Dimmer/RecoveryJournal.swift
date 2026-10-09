import Foundation

struct RecoveryJournal: Codable {
    // Keyboard keys move on a 1/16 grid; a wider tolerance can swallow the smallest key step.
    static let ownershipTolerance = 0.005

    let originalBrightness: Double
    let originalAutomatic: Bool
    var lastWritten: Double
    var pendingBrightness: Double? = nil

    func owns(_ brightness: Double) -> Bool {
        abs(brightness - lastWritten) <= Self.ownershipTolerance ||
        (pendingBrightness.map { abs(brightness - $0) <= Self.ownershipTolerance } ?? false)
    }

    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Dimmer", isDirectory: true)
        return directory.appendingPathComponent("keyboard-recovery.json")
    }

    func save(to destination: URL? = nil) throws {
        try FileManager.default.createDirectory(at: (destination ?? Self.url).deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: destination ?? Self.url, options: .atomic)
    }

    static func load(from source: URL? = nil) -> RecoveryJournal? {
        guard let data = try? Data(contentsOf: source ?? url) else { return nil }
        return try? JSONDecoder().decode(RecoveryJournal.self, from: data)
    }

    static func clear(at destination: URL? = nil) {
        try? FileManager.default.removeItem(at: destination ?? url)
    }
}
