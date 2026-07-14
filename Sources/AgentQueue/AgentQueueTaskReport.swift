import Foundation

struct AgentQueueTaskReport: Identifiable, Codable, Equatable, Sendable {
    var id: String { reportID }
    var reportID: String
    var taskID: String
    var status: AgentQueueReportStatus
    var body: String
    var bindingID: String
    var attemptNumber: Int
    var reportedAt: Date
}
