import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AgentQueueControllerTests: XCTestCase {
    func testStartDispatchesInstructionAndEnterToWorker() async throws {
        let fixture = AgentQueueControllerFixture()
        let controller = fixture.controller

        controller.createTasks(from: "Inspect repo")
        await controller.start()

        XCTAssertEqual(fixture.adapter.sentTexts.count, 1)
        XCTAssertTrue(fixture.adapter.sentTexts[0].text.contains("task_id: T-20260709-0001"))
        XCTAssertEqual(fixture.adapter.enterSurfaces, [fixture.workerSurfaceID])
        XCTAssertEqual(controller.state.tasks.first?.status, .awaitingReport)
    }

    func testWrongPaneReportIsForwardedToPlanner() async throws {
        let fixture = AgentQueueControllerFixture()
        let controller = fixture.controller

        controller.createTasks(from: "Inspect repo")
        await controller.start()
        fixture.adapter.textBySurface[fixture.workerSurfaceID] = "완료 보고 [T-20260709-0001]: done in worker pane"

        await controller.pollReportsOnce(now: fixture.now.addingTimeInterval(60))

        XCTAssertTrue(fixture.adapter.sentTexts.contains { item in
            item.surfaceID == fixture.plannerSurfaceID && item.text.contains("자동 복구 보고 [T-20260709-0001]")
        })
        XCTAssertEqual(controller.state.tasks.first?.status, .completed)
    }

    func testEnterFailureDoesNotMarkTaskAwaitingReport() async {
        let fixture = AgentQueueControllerFixture()
        fixture.adapter.enterError = AgentQueuePaneAdapterError.surfaceUnavailable(fixture.workerSurfaceID)

        fixture.controller.createTasks(from: "Inspect repo")
        await fixture.controller.start()

        XCTAssertEqual(fixture.adapter.sentTexts.count, 1)
        XCTAssertEqual(fixture.adapter.enterSurfaces, [fixture.workerSurfaceID])
        XCTAssertEqual(fixture.controller.state.tasks.first?.status, .blocked)
        XCTAssertEqual(fixture.controller.state.queue.status, .paused)
        XCTAssertNotEqual(fixture.controller.state.tasks.first?.status, .awaitingReport)
    }
}

@MainActor
private final class AgentQueueControllerFixture {
    let now: Date = {
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 9, hour: 10, minute: 11, second: 12)
        )!
    }()
    let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let plannerSurfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let workerSurfaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let adapter = FakeAgentQueuePaneAdapter()
    let controller: AgentQueueController

    init() {
        let queue = AgentQueue(
            id: "queue-1",
            workspaceID: workspaceID,
            plannerSurfaceID: plannerSurfaceID,
            status: .paused,
            createdAt: now,
            updatedAt: now
        )
        let worker = AgentWorker(
            id: "worker-1",
            workspaceID: workspaceID,
            paneID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            surfaceID: workerSurfaceID,
            label: "Worker 1",
            enabled: true,
            status: .idle,
            currentTaskID: nil,
            lastSeenAt: now
        )
        let fixedNow = now
        controller = AgentQueueController(
            initialState: AgentQueueState(queue: queue, tasks: [], workers: [worker], events: []),
            paneAdapter: adapter,
            store: nil,
            now: { fixedNow }
        )
    }
}

private final class FakeAgentQueuePaneAdapter: AgentQueuePaneAdapting, @unchecked Sendable {
    var sentTexts: [(surfaceID: UUID, text: String)] = []
    var enterSurfaces: [UUID] = []
    var textBySurface: [UUID: String] = [:]
    var enterError: Error?

    func sendText(_ text: String, to surfaceID: UUID) async throws -> AgentQueueSendResult {
        sentTexts.append((surfaceID, text))
        return AgentQueueSendResult(surfaceID: surfaceID, queued: false)
    }

    func sendEnter(to surfaceID: UUID) async throws -> AgentQueueSendResult {
        enterSurfaces.append(surfaceID)
        if let enterError {
            throw enterError
        }
        return AgentQueueSendResult(surfaceID: surfaceID, queued: false)
    }

    func readText(surfaceID: UUID, lines: Int) async throws -> AgentQueueSurfaceTextSnapshot {
        AgentQueueSurfaceTextSnapshot(
            surfaceID: surfaceID,
            text: textBySurface[surfaceID] ?? "",
            capturedAt: Date(timeIntervalSince1970: 1_782_998_400)
        )
    }
}
