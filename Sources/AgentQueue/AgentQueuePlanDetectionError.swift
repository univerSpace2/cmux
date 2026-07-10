enum AgentQueuePlanDetectionError: Error, Equatable, Sendable {
    case malformedJSON
    case emptyTasks
    case invalidTask(index: Int)
}
