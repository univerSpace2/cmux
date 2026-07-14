import Foundation

actor AgentQueueCoordinatorRegistry {
    private var coordinators: [UUID: AgentQueueCoordinator] = [:]

    func register(_ coordinator: AgentQueueCoordinator, workspaceID: UUID) {
        coordinators[workspaceID] = coordinator
    }

    func unregister(workspaceID: UUID) {
        coordinators.removeValue(forKey: workspaceID)
    }

    func coordinator(workspaceID: UUID) -> AgentQueueCoordinator? {
        coordinators[workspaceID]
    }

    func allCoordinators() -> [UUID: AgentQueueCoordinator] {
        coordinators
    }
}
