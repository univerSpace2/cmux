import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentQueueModelsTests: XCTestCase {
    func testTaskSplitterUsesTripleDashAndBlankLineBoundaries() {
        let input = """
        First task
        with details


        Second task
        ---
        Third task

        """

        XCTAssertEqual(
            AgentTaskSplitter.split(input),
            [
                "First task\nwith details",
                "Second task",
                "Third task",
            ]
        )
    }

    func testTaskIDFactoryIsStableAndSortableForSameDaySequence() {
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9, hour: 10, minute: 11, second: 12))!

        XCTAssertEqual(AgentTaskIDFactory.makeTaskID(now: date, sequence: 4), "T-20260709-0004")
        XCTAssertEqual(AgentTaskIDFactory.makeTaskID(now: date, sequence: 25), "T-20260709-0025")
    }

    func testQueueStateRoundTripsThroughJSON() throws {
        let now = Date(timeIntervalSince1970: 1_782_998_400)
        let queue = AgentQueue(
            id: "queue-workspace-1",
            workspaceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            plannerSurfaceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            status: .paused,
            createdAt: now,
            updatedAt: now
        )
        let task = AgentTask(
            id: "T-20260709-0001",
            queueID: queue.id,
            title: "Inspect repo",
            body: "Inspect repo and report findings.",
            status: .queued,
            executionMode: .sequential,
            assignedWorkerSurfaceID: nil,
            dispatchAttemptCount: 0,
            recoveryAttemptCount: 0,
            timeoutSeconds: 1_800,
            retryLimit: 3,
            createdAt: now,
            dispatchedAt: nil,
            completedAt: nil,
            lastError: nil
        )
        let state = AgentQueueState(queue: queue, tasks: [task], workers: [], events: [])

        let data = try JSONEncoder.agentQueue.encode(state)
        let decoded = try JSONDecoder.agentQueue.decode(AgentQueueState.self, from: data)

        XCTAssertEqual(decoded, state)
    }
}
