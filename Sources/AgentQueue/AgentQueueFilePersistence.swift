import Foundation

struct AgentQueueFilePersistence: AgentQueuePersisting, Sendable {
    private let rootDirectory: URL
    private let fileManager: FileManager

    init(
        rootDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-queues", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    func load(persistenceID: UUID, legacyWorkspaceID: UUID?) throws -> Data? {
        let stableURL = fileURL(id: persistenceID)
        if fileManager.fileExists(atPath: stableURL.path) {
            return try Data(contentsOf: stableURL)
        }
        guard let legacyWorkspaceID else { return nil }
        let legacyURL = fileURL(id: legacyWorkspaceID)
        guard fileManager.fileExists(atPath: legacyURL.path) else { return nil }
        return try Data(contentsOf: legacyURL)
    }

    func save(_ data: Data, persistenceID: UUID) throws {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let destination = fileURL(id: persistenceID)
        let temporary = rootDirectory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer {
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
        }

        try data.write(to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: temporary,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    func removeLegacyState(workspaceID: UUID) throws {
        let url = fileURL(id: workspaceID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func fileURL(id: UUID) -> URL {
        rootDirectory.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }
}
