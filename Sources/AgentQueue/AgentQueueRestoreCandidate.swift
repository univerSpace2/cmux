import Foundation

@MainActor
struct AgentQueueRestoreCandidate {
    let workspace: Workspace
    let tabManager: TabManager
    let persistenceID: UUID
    let legacyWorkspaceID: UUID?
}
