import Foundation

enum AgentQueueInputEvent: Equatable, Sendable {
    case queueStarted
    case queuePaused
    case dispatchSucceeded(taskID: String, workerID: String, queued: Bool)
    case enterSubmitted(taskID: String, surfaceID: UUID)
    case reportDetected(AgentQueueDetectedReport)
    case timeout(taskID: String)
    case recoverySent(taskID: String)
    case taskCancelled(taskID: String)
}

enum AgentQueueSideEffect: Equatable, Sendable {
    case dispatch(taskID: String, workerID: String)
    case sendEnter(surfaceID: UUID)
    case forwardReport(taskID: String, fromSurfaceID: UUID, excerpt: String)
    case sendCorrection(taskID: String, workerID: String)
    case sendRecovery(taskID: String, workerID: String)
    case persist
}

struct AgentQueueReduceResult: Equatable, Sendable {
    var state: AgentQueueState
    var effects: [AgentQueueSideEffect]
}

enum AgentQueueCore {
    static func reduce(
        state: AgentQueueState,
        event: AgentQueueInputEvent,
        now: Date
    ) -> AgentQueueReduceResult {
        var state = state
        var effects: [AgentQueueSideEffect] = []

        switch event {
        case .queueStarted:
            state.queue.status = .running
            state.queue.updatedAt = now
            effects.append(contentsOf: scheduleNextTasks(state: &state, now: now))

        case .queuePaused:
            state.queue.status = .paused
            state.queue.updatedAt = now

        case let .dispatchSucceeded(taskID, workerID, _):
            if let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }),
               let workerIndex = state.workers.firstIndex(where: { $0.id == workerID }) {
                state.tasks[taskIndex].status = .awaitingReport
                state.tasks[taskIndex].dispatchedAt = now
                state.tasks[taskIndex].dispatchAttemptCount += 1
                state.tasks[taskIndex].assignedWorkerSurfaceID = state.workers[workerIndex].surfaceID
                state.workers[workerIndex].status = .awaitingReport
                state.workers[workerIndex].currentTaskID = taskID
                effects.append(.sendEnter(surfaceID: state.workers[workerIndex].surfaceID))
            }

        case .enterSubmitted:
            break

        case let .reportDetected(report):
            guard let taskIndex = state.tasks.firstIndex(where: { $0.id == report.taskID }) else {
                break
            }
            if state.tasks[taskIndex].status == .completed {
                break
            }
            if report.kind == .unmatched {
                break
            }
            if report.kind == .running {
                state.tasks[taskIndex].status = .awaitingReport
                break
            }
            if report.kind == .blocked {
                state.tasks[taskIndex].status = .blocked
                state.tasks[taskIndex].lastError = report.excerpt
                state.queue.status = .paused
                releaseWorker(forTaskID: report.taskID, in: &state, status: .idle)
                break
            }

            state.tasks[taskIndex].status = .completed
            state.tasks[taskIndex].completedAt = now
            if report.location == .wrongPane {
                effects.append(
                    .forwardReport(
                        taskID: report.taskID,
                        fromSurfaceID: report.surfaceID,
                        excerpt: report.excerpt
                    )
                )
                if let worker = state.workers.first(where: { $0.currentTaskID == report.taskID }) {
                    effects.append(.sendCorrection(taskID: report.taskID, workerID: worker.id))
                }
            }
            releaseWorker(forTaskID: report.taskID, in: &state, status: .idle)
            if state.queue.status == .running {
                effects.append(contentsOf: scheduleNextTasks(state: &state, now: now))
            }

        case let .timeout(taskID):
            guard let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }) else {
                break
            }
            if state.tasks[taskIndex].recoveryAttemptCount >= state.tasks[taskIndex].retryLimit {
                state.tasks[taskIndex].status = .failed
                state.tasks[taskIndex].lastError = "Timed out after \(state.tasks[taskIndex].retryLimit) recovery attempts."
                state.queue.status = .paused
                releaseWorker(forTaskID: taskID, in: &state, status: .idle)
            } else if let worker = state.workers.first(where: { $0.currentTaskID == taskID }) {
                state.tasks[taskIndex].status = .retrying
                state.tasks[taskIndex].recoveryAttemptCount += 1
                effects.append(.sendRecovery(taskID: taskID, workerID: worker.id))
            }

        case let .recoverySent(taskID):
            if let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }) {
                state.tasks[taskIndex].status = .awaitingReport
            }

        case let .taskCancelled(taskID):
            if let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }) {
                state.tasks[taskIndex].status = .cancelled
                releaseWorker(forTaskID: taskID, in: &state, status: .idle)
            }
        }

        appendEvent(for: event, state: &state, now: now)
        return AgentQueueReduceResult(state: state, effects: effects)
    }

    private static func scheduleNextTasks(state: inout AgentQueueState, now: Date) -> [AgentQueueSideEffect] {
        guard state.queue.status == .running else {
            return []
        }

        let activeTaskExists = state.tasks.contains {
            [
                AgentTaskStatus.dispatching,
                .dispatched,
                .awaitingReport,
                .retrying,
            ].contains($0.status)
        }
        guard !activeTaskExists else {
            return []
        }
        let idleWorkerIndices = state.workers.indices.filter {
            state.workers[$0].enabled && state.workers[$0].status == .idle
        }
        guard !idleWorkerIndices.isEmpty else {
            return []
        }
        guard let firstQueuedIndex = state.tasks.firstIndex(where: { $0.status == .queued }) else {
            return []
        }

        if state.tasks[firstQueuedIndex].executionMode == .sequential {
            let workerIndex = idleWorkerIndices[0]
            let taskID = state.tasks[firstQueuedIndex].id
            let workerID = state.workers[workerIndex].id
            markAssigned(taskIndex: firstQueuedIndex, workerIndex: workerIndex, state: &state, now: now)
            return [.dispatch(taskID: taskID, workerID: workerID)]
        }

        var effects: [AgentQueueSideEffect] = []
        var workerCursor = 0
        var taskIndex = firstQueuedIndex
        while taskIndex < state.tasks.count,
              workerCursor < idleWorkerIndices.count,
              state.tasks[taskIndex].status == .queued,
              state.tasks[taskIndex].executionMode == .parallelAllowed {
            let workerIndex = idleWorkerIndices[workerCursor]
            let taskID = state.tasks[taskIndex].id
            let workerID = state.workers[workerIndex].id
            markAssigned(taskIndex: taskIndex, workerIndex: workerIndex, state: &state, now: now)
            effects.append(.dispatch(taskID: taskID, workerID: workerID))
            workerCursor += 1
            taskIndex += 1
        }
        return effects
    }

    private static func markAssigned(
        taskIndex: Int,
        workerIndex: Int,
        state: inout AgentQueueState,
        now: Date
    ) {
        state.tasks[taskIndex].status = .dispatching
        state.workers[workerIndex].status = .assigned
        state.workers[workerIndex].currentTaskID = state.tasks[taskIndex].id
        state.workers[workerIndex].lastSeenAt = now
    }

    private static func releaseWorker(
        forTaskID taskID: String,
        in state: inout AgentQueueState,
        status: AgentWorkerStatus
    ) {
        guard let workerIndex = state.workers.firstIndex(where: { $0.currentTaskID == taskID }) else {
            return
        }
        state.workers[workerIndex].status = status
        state.workers[workerIndex].currentTaskID = nil
    }

    private static func appendEvent(for event: AgentQueueInputEvent, state: inout AgentQueueState, now: Date) {
        let logType: AgentQueueLogEventType
        let taskID: String?
        switch event {
        case .queueStarted:
            logType = .queueStarted
            taskID = nil
        case .queuePaused:
            logType = .queuePaused
            taskID = nil
        case let .dispatchSucceeded(id, _, _):
            logType = .taskDispatched
            taskID = id
        case let .enterSubmitted(id, _):
            logType = .enterSubmitted
            taskID = id
        case let .reportDetected(report):
            logType = report.location == .wrongPane ? .wrongPaneReportDetected : .reportDetected
            taskID = report.taskID
        case let .timeout(id):
            logType = .timeout
            taskID = id
        case let .recoverySent(id):
            logType = .recoverySent
            taskID = id
        case let .taskCancelled(id):
            logType = .taskCancelled
            taskID = id
        }

        state.events.append(
            AgentQueueLogEvent(
                id: String(format: "event-%04d", state.events.count + 1),
                queueID: state.queue.id,
                taskID: taskID,
                workerID: nil,
                type: logType,
                message: "\(logType.rawValue)\(taskID.map { " \($0)" } ?? "")",
                evidence: nil,
                createdAt: now
            )
        )
        state.queue.updatedAt = now
    }
}
