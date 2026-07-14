import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent Queue CLI payload round trips")
struct AgentQueuePayloadRoundTripTests {
    @Test
    func enqueuePreservesQuotesBackslashesNewlinesAndUnicode() throws {
        let title = "Quote \" path \\ emoji 🧪 日本語"
        let body = "first line\nC:\\Users\\agent\\file.swift\n끝 \"quoted\""
        let source: [String: Any] = [
            "submission_id": "submission-special-1",
            "tasks": [[
                "title": title,
                "body": body,
                "execution_mode": "parallel",
                "timeout_seconds": 1_800,
                "retry_limit": 2,
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys])

        let request = try JSONDecoder.agentQueue.decode(AgentQueueEnqueueRequest.self, from: data)
        let task = try #require(request.tasks.first)
        #expect(request.submissionID == "submission-special-1")
        #expect(task.title == title)
        #expect(task.body == body)
        #expect(task.executionMode == .parallelAllowed)

        let encoded = try JSONEncoder.agentQueue.encode(request)
        let decodedAgain = try JSONDecoder.agentQueue.decode(AgentQueueEnqueueRequest.self, from: encoded)
        #expect(decodedAgain == request)
    }

    @Test
    func reportPreservesPlainUTF8BodyAndBinding() throws {
        let body = "result \\ path\n\"quoted\" 🧪 日本語 끝"
        let source: [String: Any] = [
            "task_id": "T-20260709-0001",
            "report_id": "report-special-1",
            "status": "completed",
            "binding_id": "binding-worker-1",
            "body": body,
        ]
        let data = try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys])

        let request = try JSONDecoder.agentQueue.decode(AgentQueueReportRequest.self, from: data)

        #expect(request.taskID == "T-20260709-0001")
        #expect(request.reportID == "report-special-1")
        #expect(request.status == .completed)
        #expect(request.bindingID == "binding-worker-1")
        #expect(request.body == body)
        #expect(try JSONDecoder.agentQueue.decode(
            AgentQueueReportRequest.self,
            from: JSONEncoder.agentQueue.encode(request)
        ) == request)
    }
}
