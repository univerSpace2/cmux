import Foundation

struct AgentQueueCallerContext: Codable, Equatable, Sendable {
    var workspaceID: UUID
    var surfaceID: UUID

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
    }
}

struct AgentQueueTaskDraft: Codable, Equatable, Sendable {
    var title: String
    var body: String
    var executionMode: AgentTaskExecutionMode
    var timeoutSeconds: TimeInterval
    var retryLimit: Int

    private enum CodingKeys: String, CodingKey {
        case title
        case body
        case executionMode = "execution_mode"
        case timeoutSeconds = "timeout_seconds"
        case retryLimit = "retry_limit"
    }

    init(
        title: String,
        body: String,
        executionMode: AgentTaskExecutionMode,
        timeoutSeconds: TimeInterval,
        retryLimit: Int
    ) {
        self.title = title
        self.body = body
        self.executionMode = executionMode
        self.timeoutSeconds = timeoutSeconds
        self.retryLimit = retryLimit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        timeoutSeconds = try container.decode(TimeInterval.self, forKey: .timeoutSeconds)
        retryLimit = try container.decode(Int.self, forKey: .retryLimit)
        switch try container.decode(String.self, forKey: .executionMode) {
        case "sequential":
            executionMode = .sequential
        case "parallel", "parallel_allowed":
            executionMode = .parallelAllowed
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .executionMode,
                in: container,
                debugDescription: "execution_mode must be sequential or parallel"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(
            executionMode == .parallelAllowed ? "parallel" : "sequential",
            forKey: .executionMode
        )
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(retryLimit, forKey: .retryLimit)
    }
}

struct AgentQueueEnqueueRequest: Codable, Equatable, Sendable {
    var submissionID: String
    var tasks: [AgentQueueTaskDraft]

    private enum CodingKeys: String, CodingKey {
        case submissionID = "submission_id"
        case tasks
    }
}

struct AgentQueueReportRequest: Codable, Equatable, Sendable {
    var taskID: String
    var reportID: String
    var status: AgentQueueReportStatus
    var bindingID: String
    var body: String

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case reportID = "report_id"
        case status
        case bindingID = "binding_id"
        case body
    }
}
