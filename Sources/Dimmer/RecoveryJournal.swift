import Foundation

struct RecoveryJournal: Codable {
    let originalBrightness: Double
    let originalAutomatic: Bool
    var lastWritten: Double
    var pendingBrightness: Double? = nil

    func owns(_ brightness: Double) -> Bool {
        abs(brightness - lastWritten) <= 0.035 ||
        (pendingBrightness.map { abs(brightness - $0) <= 0.035 } ?? false)
    }

    private static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Dimmer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("keyboard-recovery.json")
    }

    func save(to destination: URL? = nil) throws {
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
