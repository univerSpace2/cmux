import Foundation

enum AgentQueuePlanningPhase: String, Codable, Equatable, Sendable {
    case submitting
    case waitingForPlanner = "waiting_for_planner"
    case failed
}

struct AgentQueuePlanningRequest: Codable, Equatable, Sendable {
    var requestID: UUID
    var goal: String
    var phase: AgentQueuePlanningPhase
    var createdAt: Date
    var errorMessage: String?
}
