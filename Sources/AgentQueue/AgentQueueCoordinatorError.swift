import Foundation

enum AgentQueueCoordinatorError: Error, Equatable, Sendable {
    case conflict(String)
    case invalidRequest(String)
    case unauthorized(String)
    case notFound(String)
    case staleBinding(String)
}

struct AgentQueueEffectFailure: Error, Equatable, Sendable {
    var message: String
}

struct AgentQueueEnqueueResult: Codable, Equatable, Sendable {
    var submissionID: String
    var taskIDs: [String]
    var revision: UInt64
    var idempotent: Bool

    private enum CodingKeys: String, CodingKey {
        case submissionID = "submission_id"
        case taskIDs = "task_ids"
        case revision
        case idempotent
    }
}

struct AgentQueueReportResult: Codable, Equatable, Sendable {
    var reportID: String
    var taskID: String
    var status: AgentQueueReportStatus
    var revision: UInt64
    var idempotent: Bool

    private enum CodingKeys: String, CodingKey {
        case reportID = "report_id"
        case taskID = "task_id"
        case status
        case revision
        case idempotent
    }
}
