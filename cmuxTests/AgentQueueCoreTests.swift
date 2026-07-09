import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentQueueCoreTests: XCTestCase {
    func testStartQueueDispatchesFirstSequentialTaskToIdleWorker() {
        let fixture = AgentQueueCoreFixture.make(taskCount: 2, workerCount: 1)

        let result = AgentQueueCore.reduce(
            state: fixture.state,
            event: .queueStarted,
            now: fixture.now
        )

        XCTAssertEqual(result.state.queue.status, .running)
        XCTAssertEqual(result.state.tasks[0].status, .dispatching)
        XCTAssertEqual(result.state.workers[0].status, .assigned)
        XCTAssertEqual(result.effects, [.dispatch(taskID: "T-20260709-0001", workerID: "worker-1")])
    }

    func testSequentialTaskBlocksLaterParallelTaskUntilCompleted() {
        var fixture = AgentQueueCoreFixture.make(taskCount: 2, workerCount: 2)
        fixture.state.tasks[1].executionMode = .parallelAllowed

        let result = AgentQueueCore.reduce(
            state: fixture.state,
            event: .queueStarted,
            now: fixture.now
        )

        XCTAssertEqual(result.effects, [.dispatch(taskID: "T-20260709-0001", workerID: "worker-1")])
        XCTAssertEqual(result.state.tasks[1].status, .queued)
    }

    func testCompletedReportDispatchesNextTask() {
        var fixture = AgentQueueCoreFixture.make(taskCount: 2, workerCount: 1)
        fixture.state.queue.status = .running
        fixture.state.tasks[0].status = .awaitingReport
        fixture.state.tasks[0].assignedWorkerSurfaceID = fixture.state.workers[0].surfaceID
        fixture.state.workers[0].status = .awaitingReport
        fixture.state.workers[0].currentTaskID = "T-20260709-0001"

        let report = AgentQueueDetectedReport(
            taskID: "T-20260709-0001",
            kind: .completed,
            location: .planner,
            surfaceID: fixture.state.queue.plannerSurfaceID,
            excerpt: "완료 보고 [T-20260709-0001]: done"
        )

        let result = AgentQueueCore.reduce(
            state: fixture.state,
            event: .reportDetected(report),
            now: fixture.now.addingTimeInterval(60)
        )

        XCTAssertEqual(result.state.tasks[0].status, .completed)
        XCTAssertEqual(result.state.workers[0].status, .assigned)
        XCTAssertEqual(result.effects, [.dispatch(taskID: "T-20260709-0002", workerID: "worker-1")])
    }

    func testWrongPaneReportCreatesForwardEffectAndCompletesTask() {
        var fixture = AgentQueueCoreFixture.make(taskCount: 1, workerCount: 1)
        fixture.state.queue.status = .running
        fixture.state.tasks[0].status = .awaitingReport
        fixture.state.tasks[0].assignedWorkerSurfaceID = fixture.state.workers[0].surfaceID
        fixture.state.workers[0].status = .awaitingReport
        fixture.state.workers[0].currentTaskID = "T-20260709-0001"

        let report = AgentQueueDetectedReport(
            taskID: "T-20260709-0001",
            kind: .completed,
            location: .wrongPane,
            surfaceID: fixture.state.workers[0].surfaceID,
            excerpt: "완료 보고 [T-20260709-0001]: done in wrong pane"
        )

        let result = AgentQueueCore.reduce(state: fixture.state, event: .reportDetected(report), now: fixture.now)

        XCTAssertEqual(result.state.tasks[0].status, .completed)
        XCTAssertEqual(result.effects, [
            .forwardReport(taskID: "T-20260709-0001", fromSurfaceID: fixture.state.workers[0].surfaceID, excerpt: "완료 보고 [T-20260709-0001]: done in wrong pane"),
            .sendCorrection(taskID: "T-20260709-0001", workerID: "worker-1"),
        ])
    }

    func testTimeoutSendsRecoveryUntilRetryLimitThenPausesQueue() {
        var fixture = AgentQueueCoreFixture.make(taskCount: 1, workerCount: 1)
        fixture.state.queue.status = .running
        fixture.state.tasks[0].status = .awaitingReport
        fixture.state.tasks[0].recoveryAttemptCount = 3
        fixture.state.tasks[0].retryLimit = 3
        fixture.state.workers[0].status = .awaitingReport
        fixture.state.workers[0].currentTaskID = "T-20260709-0001"

        let result = AgentQueueCore.reduce(
            state: fixture.state,
            event: .timeout(taskID: "T-20260709-0001"),
            now: fixture.now
        )

        XCTAssertEqual(result.state.tasks[0].status, .failed)
        XCTAssertEqual(result.state.queue.status, .paused)
        XCTAssertEqual(result.effects, [])
    }
}

struct AgentQueueCoreFixture {
    var now: Date
    var state: AgentQueueState

    static func make(taskCount: Int, workerCount: Int) -> AgentQueueCoreFixture {
        let now = Date(timeIntervalSince1970: 1_782_998_400)
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let plannerSurfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let queue = AgentQueue(
            id: "queue-1",
            workspaceID: workspaceID,
            plannerSurfaceID: plannerSurfaceID,
            status: .paused,
            createdAt: now,
            updatedAt: now
        )
        let tasks = (1...taskCount).map { index in
            AgentTask(
                id: String(format: "T-20260709-%04d", index),
                queueID: queue.id,
                title: "Task \(index)",
                body: "Body \(index)",
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
        }
        let workers = (1...workerCount).map { index in
            AgentWorker(
                id: "worker-\(index)",
                workspaceID: workspaceID,
                paneID: UUID(uuidString: String(format: "aaaaaaaa-aaaa-aaaa-aaaa-%012d", index))!,
                surfaceID: UUID(uuidString: String(format: "bbbbbbbb-bbbb-bbbb-bbbb-%012d", index))!,
                label: "Worker \(index)",
                enabled: true,
                status: .idle,
                currentTaskID: nil,
                lastSeenAt: now
            )
        }
        return AgentQueueCoreFixture(now: now, state: AgentQueueState(queue: queue, tasks: tasks, workers: workers, events: []))
    }
}
