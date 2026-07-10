import Foundation

enum AgentQueuePlanDetector {
    private static let openingMarker = "[AGENT_QUEUE_TASKS]"
    private static let closingMarker = "[/AGENT_QUEUE_TASKS]"

    static func detect(
        in text: String
    ) -> Result<AgentQueuePlannedTasks, AgentQueuePlanDetectionError>? {
        guard
            let closingRange = text.range(of: closingMarker, options: .backwards),
            let openingRange = text.range(
                of: openingMarker,
                options: .backwards,
                range: text.startIndex..<closingRange.lowerBound
            )
        else {
            return nil
        }

        let payloadText = text[openingRange.upperBound..<closingRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: Data(payloadText.utf8))
        } catch {
            return .failure(.malformedJSON)
        }

        guard !payload.tasks.isEmpty else {
            return .failure(.emptyTasks)
        }

        var tasks: [AgentQueuePlannedTask] = []
        tasks.reserveCapacity(payload.tasks.count)
        for (index, task) in payload.tasks.enumerated() {
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = task.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !body.isEmpty else {
                return .failure(.invalidTask(index: index))
            }
            tasks.append(AgentQueuePlannedTask(title: title, body: body))
        }

        return .success(AgentQueuePlannedTasks(
            requestID: payload.requestID,
            tasks: tasks
        ))
    }
}

private struct Payload: Decodable {
    var requestID: UUID
    var tasks: [Task]

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case tasks
    }

    struct Task: Decodable {
        var title: String
        var body: String
    }
}
