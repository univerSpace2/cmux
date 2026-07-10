import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentQueueStoreTests: XCTestCase {
    func testStoreSavesAndLoadsWorkspaceState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = AgentQueueStore(rootDirectory: directory)
        let state = AgentQueueStoreFixture.state(eventCount: 2)

        try await store.save(state)
        let loaded = try await store.load(workspaceID: state.queue.workspaceID)

        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded?.preparation?.configuration, .defaultConfiguration)
    }

    func testPruneEventsKeepsNewestEvents() {
        let state = AgentQueueStoreFixture.state(eventCount: 5)

        let pruned = AgentQueueStore.pruneEvents(in: state, limit: 2)

        XCTAssertEqual(pruned.events.map(\.message), ["event-4", "event-5"])
    }
}

private enum AgentQueueStoreFixture {
    static func state(eventCount: Int) -> AgentQueueState {
        let now = Date(timeIntervalSince1970: 1_782_998_400)
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let queue = AgentQueue(
            id: "queue-1",
            workspaceID: workspaceID,
            plannerSurfaceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            status: .paused,
            createdAt: now,
            updatedAt: now
        )
        let events = (1...eventCount).map { index in
            AgentQueueLogEvent(
                id: "event-\(index)",
                queueID: queue.id,
                taskID: nil,
                workerID: nil,
                type: .taskCreated,
                message: "event-\(index)",
                evidence: nil,
                createdAt: now.addingTimeInterval(TimeInterval(index))
            )
        }
        return AgentQueueState(
            queue: queue,
            tasks: [],
            workers: [],
            events: events,
            preparation: AgentQueuePreparationState(
                configuration: .defaultConfiguration,
                phase: .notPrepared,
                completedWorkerCount: 0,
                errorMessage: nil
            )
        )
    }
}
