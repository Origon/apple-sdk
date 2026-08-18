import Foundation

enum InstallationIdentity {
    private static let lock = NSLock()

    static func loadOrCreate() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw OrigonError(kind: .other, message: "installation identity: no application support directory")
        }
        let directory = base.appendingPathComponent("ai.origon.sdk", isDirectory: true)
        let file = directory.appendingPathComponent("installation-id", isDirectory: false)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackup(directory)

        if let raw = try? String(contentsOf: file, encoding: .utf8),
           let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return uuid.uuidString.lowercased()
        }

        let value = UUID().uuidString.lowercased()
        try Data(value.utf8).write(to: file, options: .atomic)
        try excludeFromBackup(file)
        return value
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }
}
