enum AgentQueueReportStatus: String, Codable, Equatable, Sendable {
    case completed
    case failed
    case blocked
}
