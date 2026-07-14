import Foundation

struct AgentQueueAgentBinding: Identifiable, Codable, Equatable, Sendable {
    var id: String { bindingID }
    var bindingID: String
    var agentID: String
    var role: AgentQueueAgentRole
    var workspaceID: UUID
    var paneID: UUID?
    var surfaceID: UUID?
    var readiness: AgentQueueAgentReadiness
    var preparedAt: Date
    var readyDeadline: Date?
    var readyAt: Date?
    var lastSeenAt: Date?
    var observedSessionID: String?
}
