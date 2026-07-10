import Foundation

struct AgentQueuePlannedTasks: Equatable, Sendable {
    var requestID: UUID
    var tasks: [AgentQueuePlannedTask]
}
