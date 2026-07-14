import Foundation

protocol AgentQueuePersisting: Sendable {
    func load(persistenceID: UUID, legacyWorkspaceID: UUID?) throws -> Data?
    func save(_ data: Data, persistenceID: UUID) throws
    func removeLegacyState(workspaceID: UUID) throws
}
