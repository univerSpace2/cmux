import Foundation

actor AgentQueueStore {
    private let rootDirectory: URL
    private let fileManager: FileManager

    init(
        rootDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-queues", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    func load(workspaceID: UUID) async throws -> AgentQueueState? {
        let url = fileURL(workspaceID: workspaceID)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder.agentQueue.decode(AgentQueueState.self, from: data)
    }

    func save(_ state: AgentQueueState) async throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let data = try JSONEncoder.agentQueue.encode(state)
        let url = fileURL(workspaceID: state.queue.workspaceID)
        let temporaryURL = url.appendingPathExtension("tmp")
        try data.write(to: temporaryURL, options: [.atomic])
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: temporaryURL, to: url)
    }

    private func fileURL(workspaceID: UUID) -> URL {
        rootDirectory.appendingPathComponent("\(workspaceID.uuidString.lowercased()).json")
    }

    static func pruneEvents(in state: AgentQueueState, limit: Int) -> AgentQueueState {
        guard state.events.count > limit else {
            return state
        }

        var copy = state
        copy.events = Array(state.events.suffix(limit))
        return copy
    }
}
