import Foundation

struct AgentQueueSubmission: Identifiable, Codable, Equatable, Sendable {
    var id: String { submissionID }
    var submissionID: String
    var payloadDigest: String
    var taskIDs: [String]
    var createdAt: Date
}
