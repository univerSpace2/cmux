import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct AgentQueueCoreTests {
    @Test func enqueueFillsOnlyReadyLiveIdleCapacity() {
        var fixture = AgentQueueCoreFixture.make(taskCount: 3, workerCount: 3)
        fixture.state.workers[2].bindingID = nil
        let submission = fixture.submission(taskIDs: fixture.state.tasks.map(\.id))

        let result = AgentQueueCore().reduce(
            state: fixture.state,
            event: .tasksEnqueued(tasks: [], submission: submission),
            now: fixture.now
        )

        #expect(result.effects == [
            .dispatch(taskID: "T-20260709-0001", workerID: "worker-1", bindingID: "binding-worker-1"),
            .dispatch(taskID: "T-20260709-0002", workerID: "worker-2", bindingID: "binding-worker-2"),
        ])
        #expect(result.state.tasks[2].status == .queued)
    }

    @Test func enqueueWhilePausedDoesNotResume() {
        var fixture = AgentQueueCoreFixture.make(taskCount: 0, workerCount: 1)
        fixture.state.queue.status = .paused
        let task = fixture.task(id: "T-20260709-0001", mode: .parallelAllowed)

        let result = AgentQueueCore().reduce(
            state: fixture.state,
            event: .tasksEnqueued(
                tasks: [task],
                submission: fixture.submission(taskIDs: [task.id])
            ),
            now: fixture.now
        )

        #expect(result.state.queue.status == .paused)
        #expect(result.state.tasks == [task])
        #expect(result.effects.isEmpty)
    }

    @Test func sequentialTaskRunsAloneUntilItCompletes() {
        var fixture = AgentQueueCoreFixture.make(taskCount: 3, workerCount: 2)
        fixture.state.tasks[0].executionMode = .sequential

        let result = AgentQueueCore().reduce(
            state: fixture.state,
            event: .tasksEnqueued(
                tasks: [],
                submission: fixture.submission(taskIDs: fixture.state.tasks.map(\.id))
            ),
            now: fixture.now
        )

        #expect(result.effects == [
            .dispatch(taskID: "T-20260709-0001", workerID: "worker-1", bindingID: "binding-worker-1"),
        ])
        #expect(result.state.tasks[1].status == .queued)
        #expect(result.state.workers[1].status == .idle)
    }

    @Test func completedReportSchedulesNextQueuedTask() {
        var fixture = AgentQueueCoreFixture.make(taskCount: 2, workerCount: 1)
        fixture.assign(taskIndex: 0, workerIndex: 0)
        let report = fixture.report(id: "report-completed", status: .completed)

        let result = AgentQueueCore().reduce(
            state: fixture.state,
            event: .taskReported(report),
            now: fixture.now.addingTimeInterval(60)
        )

        #expect(result.state.tasks[0].status == .completed)
        #expect(result.state.reports == [report])
        #expect(result.effects == [
            .dispatch(taskID: "T-20260709-0002", workerID: "worker-1", bindingID: "binding-worker-1"),
        ])
    }

    @Test func failedReportRecoversOnceThenFailsAndPauses() {
        var fixture = AgentQueueCoreFixture.make(taskCount: 1, workerCount: 1)
        fixture.assign(taskIndex: 0, workerIndex: 0)
        fixture.state.tasks[0].retryLimit = 1

        let firstReport = fixture.report(id: "report-failed-1", status: .failed)
        let first = AgentQueueCore().reduce(
            state: fixture.state,
            event: .taskReported(firstReport),
            now: fixture.now
        )

        #expect(first.state.tasks[0].status == .retrying)
        #expect(first.state.tasks[0].recoveryAttemptCount == 1)
        #expect(first.state.workers[0].currentTaskID == "T-20260709-0001")
        #expect(first.effects == [
            .recover(taskID: "T-20260709-0001", workerID: "worker-1", bindingID: "binding-worker-1"),
        ])

        var secondFixture = fixture
        secondFixture.state = first.state
        let secondReport = secondFixture.report(id: "report-failed-2", status: .failed)
        let second = AgentQueueCore().reduce(
            state: secondFixture.state,
            event: .taskReported(secondReport),
            now: fixture.now.addingTimeInterval(1)
        )

        #expect(second.state.tasks[0].status == .failed)
        #expect(second.state.workers[0].status == .idle)
        #expect(second.state.workers[0].currentTaskID == nil)
        #expect(second.state.queue.status == .paused)
        #expect(second.effects.isEmpty)
    }

    @Test func blockedReportReleasesWorkerAndPauses() {
        var fixture = AgentQueueCoreFixture.make(taskCount: 1, workerCount: 1)
        fixture.assign(taskIndex: 0, workerIndex: 0)

        let result = AgentQueueCore().reduce(
            state: fixture.state,
            event: .taskReported(fixture.report(id: "report-blocked", status: .blocked)),
            now: fixture.now
        )

        #expect(result.state.tasks[0].status == .blocked)
        #expect(result.state.workers[0].status == .idle)
        #expect(result.state.queue.status == .paused)
    }

    @Test func dispatchSuccessTransitionsToDispatchedAndRunning() {
        var fixture = AgentQueueCoreFixture.make(taskCount: 1, workerCount: 1)
        fixture.state.tasks[0].status = .dispatching
        fixture.state.workers[0].status = .assigned
        fixture.state.workers[0].currentTaskID = fixture.state.tasks[0].id

        let result = AgentQueueCore().reduce(
            state: fixture.state,
            event: .dispatchSubmitted(
                taskID: "T-20260709-0001",
                workerID: "worker-1",
                bindingID: "binding-worker-1",
                queued: false
            ),
            now: fixture.now
        )

        #expect(result.state.tasks[0].status == .dispatched)
        #expect(result.state.tasks[0].dispatchAttemptCount == 1)
        #expect(result.state.workers[0].status == .running)
    }

    @Test func activeWorkerRemovalBlocksAndPauses() {
        var fixture = AgentQueueCoreFixture.make(taskCount: 1, workerCount: 1)
        fixture.assign(taskIndex: 0, workerIndex: 0)

        let result = AgentQueueCore().reduce(
            state: fixture.state,
            event: .agentRemoved(
                agentID: "worker-1",
                bindingID: "binding-worker-1",
                cause: "surface_closed"
            ),
            now: fixture.now
        )

        #expect(result.state.tasks[0].status == .blocked)
        #expect(result.state.queue.status == .paused)
        #expect(result.state.workers.isEmpty)
        #expect(result.state.bindings.map(\.role) == [.planner])
        #expect(result.effects.isEmpty)
    }

    @Test func idleWorkerRemovalLeavesQueueRunning() {
        let fixture = AgentQueueCoreFixture.make(taskCount: 0, workerCount: 1)

        let result = AgentQueueCore().reduce(
            state: fixture.state,
            event: .agentRemoved(
                agentID: "worker-1",
                bindingID: "binding-worker-1",
                cause: "manual"
            ),
            now: fixture.now
        )

        #expect(result.state.queue.status == .running)
        #expect(result.state.workers.isEmpty)
        #expect(result.state.bindings.map(\.role) == [.planner])
    }

    @Test func plannerRemovalClearsRegistrationAndPauses() throws {
        let fixture = AgentQueueCoreFixture.make(taskCount: 1, workerCount: 1)

        let result = AgentQueueCore().reduce(
            state: fixture.state,
            event: .agentRemoved(
                agentID: AgentQueueAgentID.planner,
                bindingID: "binding-planner-1",
                cause: "manual"
            ),
            now: fixture.now
        )

        let planner = try #require(result.state.bindings.first(where: { $0.role == .planner }))
        #expect(planner.surfaceID == nil)
        #expect(planner.readiness == .notReady)
        #expect(result.state.queue.status == .paused)
    }

    @Test func timeoutBlocksTaskRemovesWorkerAndPauses() {
        var fixture = AgentQueueCoreFixture.make(taskCount: 1, workerCount: 1)
        fixture.assign(taskIndex: 0, workerIndex: 0)

        let result = AgentQueueCore().reduce(
            state: fixture.state,
            event: .taskTimedOut(
                taskID: "T-20260709-0001",
                bindingID: "binding-worker-1"
            ),
            now: fixture.now
        )

        #expect(result.state.tasks[0].status == .blocked)
        #expect(result.state.workers.isEmpty)
        #expect(result.state.bindings.map(\.role) == [.planner])
        #expect(result.state.queue.status == .paused)
        #expect(result.effects.isEmpty)
    }
}

struct AgentQueueCoreFixture {
    var now: Date
    var state: AgentQueueState

    static func make(taskCount: Int, workerCount: Int) -> AgentQueueCoreFixture {
        let now = Date(timeIntervalSince1970: 1_783_555_200)
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let plannerSurfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let queue = AgentQueue(
            id: "queue-1",
            workspaceID: workspaceID,
            status: .running,
            createdAt: now,
            updatedAt: now
        )
        let tasks = (0..<taskCount).map { offset in
            makeTask(
                id: String(format: "T-20260709-%04d", offset + 1),
                queueID: queue.id,
                now: now,
                mode: .parallelAllowed
            )
        }
        let workers = (0..<workerCount).map { offset in
            let index = offset + 1
            return AgentWorker(
                id: "worker-\(index)",
                workspaceID: workspaceID,
                paneID: UUID(uuidString: String(format: "aaaaaaaa-aaaa-aaaa-aaaa-%012d", index))!,
                surfaceID: UUID(uuidString: String(format: "bbbbbbbb-bbbb-bbbb-bbbb-%012d", index))!,
                label: "Worker \(index)",
                enabled: true,
                status: .idle,
                currentTaskID: nil,
                lastSeenAt: now,
                bindingID: "binding-worker-\(index)"
            )
        }
        let plannerBinding = AgentQueueAgentBinding(
            bindingID: "binding-planner-1",
            agentID: AgentQueueAgentID.planner,
            role: .planner,
            workspaceID: workspaceID,
            paneID: nil,
            surfaceID: plannerSurfaceID,
            readiness: .ready,
            preparedAt: now,
            readyDeadline: now.addingTimeInterval(30),
            readyAt: now,
            lastSeenAt: now,
            observedSessionID: "session-planner-1"
        )
        let workerBindings = workers.enumerated().map { offset, worker in
            AgentQueueAgentBinding(
                bindingID: "binding-worker-\(offset + 1)",
                agentID: worker.id,
                role: .worker,
                workspaceID: workspaceID,
                paneID: worker.paneID,
                surfaceID: worker.surfaceID,
                readiness: .ready,
                preparedAt: now,
                readyDeadline: now.addingTimeInterval(30),
                readyAt: now,
                lastSeenAt: now,
                observedSessionID: "session-worker-\(offset + 1)"
            )
        }
        return AgentQueueCoreFixture(
            now: now,
            state: AgentQueueState(
                queue: queue,
                tasks: tasks,
                workers: workers,
                bindings: [plannerBinding] + workerBindings,
                events: []
            )
        )
    }

    func task(id: String, mode: AgentTaskExecutionMode) -> AgentTask {
        Self.makeTask(id: id, queueID: state.queue.id, now: now, mode: mode)
    }

    func submission(taskIDs: [String]) -> AgentQueueSubmission {
        AgentQueueSubmission(
            submissionID: "submission-1",
            payloadDigest: "digest-1",
            taskIDs: taskIDs,
            createdAt: now
        )
    }

    mutating func assign(taskIndex: Int, workerIndex: Int) {
        state.tasks[taskIndex].status = .dispatched
        state.tasks[taskIndex].assignedWorkerSurfaceID = state.workers[workerIndex].surfaceID
        state.tasks[taskIndex].dispatchedAt = now
        state.workers[workerIndex].status = .running
        state.workers[workerIndex].currentTaskID = state.tasks[taskIndex].id
    }

    func report(id: String, status: AgentQueueReportStatus) -> AgentQueueTaskReport {
        AgentQueueTaskReport(
            reportID: id,
            taskID: state.tasks[0].id,
            status: status,
            body: "Report \(id)",
            bindingID: state.workers[0].bindingID!,
            attemptNumber: state.tasks[0].recoveryAttemptCount + 1,
            reportedAt: now
        )
    }

    private static func makeTask(
        id: String,
        queueID: String,
        now: Date,
        mode: AgentTaskExecutionMode
    ) -> AgentTask {
        AgentTask(
            id: id,
            queueID: queueID,
            title: "Task \(id)",
            body: "Body \(id)",
            status: .queued,
            executionMode: mode,
            assignedWorkerSurfaceID: nil,
            dispatchAttemptCount: 0,
            recoveryAttemptCount: 0,
            timeoutSeconds: 1_800,
            retryLimit: 1,
            createdAt: now,
            dispatchedAt: nil,
            completedAt: nil,
            lastError: nil
        )
    }
}
