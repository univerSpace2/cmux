import Foundation
import Testing
@testable import CmuxControlSocket

@Suite("Agent Queue control socket domain")
struct ControlCommandCoordinatorAgentQueueTests {
    private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let surfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test
    func enqueueForwardsExactTypedPayload() async throws {
        let context = RecordingAgentQueueContext()
        let coordinator = await MainActor.run { ControlCommandCoordinator() }
        let exactBody = "Quotes: \"double\"\\nPath: C:\\\\Users\\\\agent\\nUnicode: 작업 計画 🚀"
        let submission: JSONValue = .object([
            "submission_id": .string("submission-special-1"),
            "tasks": .array([
                .object([
                    "title": .string("Parser \\ \"quotes\" 작업"),
                    "body": .string(exactBody),
                    "execution_mode": .string("parallel"),
                    "timeout_seconds": .int(1_800),
                    "retry_limit": .int(1),
                ]),
            ]),
        ])

        let result = await coordinator.handleAgentQueue(
            request(
                method: "agent_queue.task.enqueue",
                extra: ["submission": submission]
            ),
            context: context
        )
        let call = try #require(await context.calls().first)

        #expect(result == .ok(.object(["accepted": .bool(true)])))
        #expect(call.method == "agent_queue.task.enqueue")
        #expect(call.workspaceID == workspaceID)
        #expect(call.surfaceID == surfaceID)
        #expect(call.params["submission"] == submission)
        guard case .object(let object)? = call.params["submission"],
              case .array(let tasks)? = object["tasks"],
              case .object(let task) = tasks[0] else {
            Issue.record("Expected typed submission payload")
            return
        }
        #expect(task["body"] == .string(exactBody))
    }

    @Test(arguments: [
        "agent_queue.agent.ready",
        "agent_queue.agent.offline",
        "agent_queue.agent.list",
        "agent_queue.agent.remove",
        "agent_queue.agent.reconcile",
        "agent_queue.task.enqueue",
        "agent_queue.task.report",
        "agent_queue.task.list",
        "agent_queue.pause",
        "agent_queue.resume",
    ])
    func methodsRunOnlyOnSocketWorker(_ method: String) {
        #expect(ControlCommandExecutionPolicy(forMethod: method) == .socketWorker(mainThreadCallable: false))
    }

    @Test
    func malformedCallerContextRejectsWithoutInvokingContext() async {
        let context = RecordingAgentQueueContext()
        let coordinator = await MainActor.run { ControlCommandCoordinator() }
        let result = await coordinator.handleAgentQueue(
            ControlRequest(
                id: .int(1),
                method: "agent_queue.pause",
                params: [
                    "workspace_id": .string("not-a-uuid"),
                    "surface_id": .string(surfaceID.uuidString),
                ]
            ),
            context: context
        )

        guard case .err(let code, _, _) = result else {
            Issue.record("Expected invalid_params")
            return
        }
        #expect(code == "invalid_params")
        #expect(await context.calls().isEmpty)
    }

    @Test
    func malformedMethodPayloadRejectsWithoutInvokingContext() async {
        let context = RecordingAgentQueueContext()
        let coordinator = await MainActor.run { ControlCommandCoordinator() }
        let result = await coordinator.handleAgentQueue(
            request(
                method: "agent_queue.task.report",
                extra: [
                    "task_id": .string("task-1"),
                    "report_id": .string("report-1"),
                    "status": .string("completed"),
                    "binding_id": .string("binding-1"),
                    "body": .array([]),
                ]
            ),
            context: context
        )

        guard case .err(let code, _, _) = result else {
            Issue.record("Expected invalid_params")
            return
        }
        #expect(code == "invalid_params")
        #expect(await context.calls().isEmpty)
    }

    @Test
    func unknownMethodFallsThrough() async {
        let context = RecordingAgentQueueContext()
        let coordinator = await MainActor.run { ControlCommandCoordinator() }
        let result = await coordinator.handleAgentQueue(
            request(method: "agent_queue.unknown", extra: [:]),
            context: context
        )

        #expect(result == nil)
        #expect(await context.calls().isEmpty)
    }

    private func request(method: String, extra: [String: JSONValue]) -> ControlRequest {
        ControlRequest(
            id: .int(1),
            method: method,
            params: extra.merging([
                "workspace_id": .string(workspaceID.uuidString),
                "surface_id": .string(surfaceID.uuidString),
            ]) { current, _ in current }
        )
    }
}

private actor RecordingAgentQueueContext: ControlAgentQueueContext {
    private var recordedCalls: [ControlAgentQueueCall] = []

    nonisolated func controlAgentQueue(_ call: ControlAgentQueueCall) async -> ControlCallResult {
        await record(call)
        return .ok(.object(["accepted": .bool(true)]))
    }

    func calls() -> [ControlAgentQueueCall] {
        recordedCalls
    }

    private func record(_ call: ControlAgentQueueCall) {
        recordedCalls.append(call)
    }
}
