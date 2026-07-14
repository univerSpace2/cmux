enum AgentQueueAgentReadiness: String, Codable, Equatable, Sendable {
    case pending
    case ready
    case notReady = "not_ready"
}
