import Foundation

enum AgentQueueInputEvent: Equatable, Sendable {
    case queueStarted
    case queuePaused
    case dispatchSubmitted(taskID: String, workerID: String, queued: Bool)
    case dispatchSubmissionFailed(
        taskID: String,
        workerID: String,
        stage: AgentQueueDispatchFailureStage,
        message: String
    )
    case reportDetected(AgentQueueDetectedReport)
    case ignoredReport(surfaceID: UUID, excerpt: String, reason: String)
    case timeout(taskID: String)
    case recoverySent(taskID: String)
    case taskCancelled(taskID: String)
}

enum AgentQueueSideEffect: Equatable, Sendable {
    case dispatch(taskID: String, workerID: String)
    case forwardReport(taskID: String, fromSurfaceID: UUID, excerpt: String)
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

        case let .dispatchSubmitted(taskID, workerID, _):
            if let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }),
               let workerIndex = state.workers.firstIndex(where: { $0.id == workerID }) {
                state.tasks[taskIndex].status = .awaitingReport
                state.tasks[taskIndex].dispatchedAt = now
                state.tasks[taskIndex].dispatchAttemptCount += 1
                state.tasks[taskIndex].assignedWorkerSurfaceID = state.workers[workerIndex].surfaceID
                state.workers[workerIndex].status = .awaitingReport
                state.workers[workerIndex].currentTaskID = taskID
            }

        case let .dispatchSubmissionFailed(taskID, workerID, stage, message):
            if let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }) {
                state.tasks[taskIndex].status = stage == .text ? .failed : .blocked
                state.tasks[taskIndex].lastError = message
            }
            if let workerIndex = state.workers.firstIndex(where: { $0.id == workerID }) {
                state.workers[workerIndex].status = .offline
                state.workers[workerIndex].currentTaskID = taskID
            }
            state.queue.status = .paused

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
            }
            releaseWorker(forTaskID: report.taskID, in: &state, status: .idle)
            if state.queue.status == .running {
                effects.append(contentsOf: scheduleNextTasks(state: &state, now: now))
            }

        case .ignoredReport:
            break

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

        appendEvents(for: event, state: &state, now: now)
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

    private static func appendEvents(for event: AgentQueueInputEvent, state: inout AgentQueueState, now: Date) {
        switch event {
        case let .dispatchSubmitted(taskID, workerID, _):
            appendEvent(type: .taskDispatched, taskID: taskID, workerID: workerID, evidence: nil, state: &state, now: now)
            appendEvent(type: .enterSubmitted, taskID: taskID, workerID: workerID, evidence: nil, state: &state, now: now)
            state.queue.updatedAt = now
            return

        case let .dispatchSubmissionFailed(taskID, workerID, stage, message):
            let worker = state.workers.first(where: { $0.id == workerID })
            appendEvent(
                type: .taskFailed,
                taskID: taskID,
                workerID: workerID,
                evidence: AgentQueueLogEvidence(
                    workspaceID: state.queue.workspaceID,
                    paneID: worker?.paneID,
                    surfaceID: worker?.surfaceID,
                    command: stage.rawValue,
                    screenExcerpt: message
                ),
                state: &state,
                now: now
            )
            state.queue.updatedAt = now
            return

        case let .ignoredReport(surfaceID, excerpt, reason):
            appendEvent(
                type: .ignoredReport,
                taskID: nil,
                workerID: nil,
                evidence: AgentQueueLogEvidence(
                    workspaceID: state.queue.workspaceID,
                    paneID: nil,
                    surfaceID: surfaceID,
                    command: reason,
                    screenExcerpt: excerpt
                ),
                state: &state,
                now: now
            )
            state.queue.updatedAt = now
            return

        default:
            break
        }

        let logType: AgentQueueLogEventType
        let taskID: String?
        switch event {
        case .queueStarted:
            logType = .queueStarted
            taskID = nil
        case .queuePaused:
            logType = .queuePaused
            taskID = nil
        case .dispatchSubmitted, .dispatchSubmissionFailed:
            return
        case let .reportDetected(report):
            logType = report.location == .wrongPane ? .wrongPaneReportDetected : .reportDetected
            taskID = report.taskID
        case .ignoredReport:
            return
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

        appendEvent(type: logType, taskID: taskID, workerID: nil, evidence: nil, state: &state, now: now)
        state.queue.updatedAt = now
    }

    private static func appendEvent(
        type: AgentQueueLogEventType,
        taskID: String?,
        workerID: String?,
        evidence: AgentQueueLogEvidence?,
        state: inout AgentQueueState,
        now: Date
    ) {
        state.events.append(
            AgentQueueLogEvent(
                id: String(format: "event-%04d", state.events.count + 1),
                queueID: state.queue.id,
                taskID: taskID,
                workerID: workerID,
                type: type,
                message: "\(type.rawValue)\(taskID.map { " \($0)" } ?? "")",
                evidence: evidence,
                createdAt: now
            )
        )
    }
}
