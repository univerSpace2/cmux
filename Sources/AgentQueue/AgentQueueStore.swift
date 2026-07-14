import Foundation

@available(*, deprecated, message: "Use AgentQueueCoordinator with AgentQueueFilePersistence")
actor AgentQueueStore {
    private let persistence: AgentQueueFilePersistence
    private let migration = AgentQueueStateMigration()

    init(
        rootDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-queues", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        persistence = AgentQueueFilePersistence(
            rootDirectory: rootDirectory,
            fileManager: fileManager
        )
    }

    func load(workspaceID: UUID) throws -> AgentQueueState? {
        guard let data = try persistence.load(
            persistenceID: workspaceID,
            legacyWorkspaceID: nil
        ) else { return nil }
        return try migration.decode(data)
    }

    func save(_ state: AgentQueueState) throws {
        try persistence.save(
            JSONEncoder.agentQueue.encode(state),
            persistenceID: state.queue.workspaceID
        )
    }

    static func pruneEvents(in state: AgentQueueState, limit: Int) -> AgentQueueState {
        guard state.events.count > limit else { return state }
        var copy = state
        copy.events = Array(state.events.suffix(limit))
        return copy
    }
}
