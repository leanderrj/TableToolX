import Foundation

struct RecoveryRecord: Codable, Identifiable {
    var id: UUID
    var workspaceURL: URL
    var sourceURL: URL?
    var sourceBookmark: Data?
    var displayName: String
    var modifiedAt: Date
}

enum RecoveryManager {
    private static var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TableToolX", isDirectory: true)
    }

    private static var manifestURL: URL {
        let root = applicationSupportURL
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root.appendingPathComponent("Recovery.json")
    }

    static func records() -> [RecoveryRecord] {
        let records: [RecoveryRecord]
        if let data = try? Data(contentsOf: manifestURL), let decoded = try? JSONDecoder().decode([RecoveryRecord].self, from: data) {
            records = decoded
        } else {
            records = []
        }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let active = records.filter { $0.modifiedAt >= cutoff && FileManager.default.fileExists(atPath: $0.workspaceURL.path) }
        for stale in records where !active.contains(where: { $0.id == stale.id }) {
            deleteWorkspaceFiles(stale.workspaceURL)
        }
        if active.count != records.count { write(active) }
        pruneUntrackedWorkspaces(keeping: Set(active.map { $0.workspaceURL.standardizedFileURL.path }), olderThan: cutoff)
        return active
    }

    static func store(_ record: RecoveryRecord) {
        var current = records().filter { $0.id != record.id }
        current.append(record)
        write(current)
    }

    static func remove(id: UUID, workspaceURL: URL, deleteWorkspace: Bool) {
        write(records().filter { $0.id != id })
        guard deleteWorkspace else { return }
        deleteWorkspaceFiles(workspaceURL)
    }

    static func clearAll() {
        for record in records() { remove(id: record.id, workspaceURL: record.workspaceURL, deleteWorkspace: true) }
        try? FileManager.default.removeItem(at: manifestURL)
    }

    private static func write(_ records: [RecoveryRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private static func deleteWorkspaceFiles(_ workspaceURL: URL) {
        for url in [workspaceURL, URL(fileURLWithPath: workspaceURL.path + "-wal"), URL(fileURLWithPath: workspaceURL.path + "-shm")] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func pruneUntrackedWorkspaces(keeping paths: Set<String>, olderThan cutoff: Date) {
        let root = applicationSupportURL.appendingPathComponent("Workspaces", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.pathExtension == "sqlite" && !paths.contains(url.standardizedFileURL.path) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate, modified < cutoff else { continue }
            deleteWorkspaceFiles(url)
        }
    }
}
