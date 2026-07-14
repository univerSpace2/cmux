import Foundation

enum AgentQueueStateMigrationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

struct AgentQueueStateMigration: Sendable {
    func schemaVersion(in data: Data) throws -> Int {
        let probe = try JSONDecoder.agentQueue.decode(SchemaVersionProbe.self, from: data)
        return probe.schemaVersion ?? 1
    }

    func decode(_ data: Data) throws -> AgentQueueState {
        switch try schemaVersion(in: data) {
        case AgentQueueState.currentSchemaVersion:
            return try JSONDecoder.agentQueue.decode(AgentQueueState.self, from: data)
        case 1:
            return try migrate(JSONDecoder.agentQueue.decode(LegacyAgentQueueStateV1.self, from: data))
        case let version:
            throw AgentQueueStateMigrationError.unsupportedSchemaVersion(version)
        }
    }

    private func migrate(_ legacy: LegacyAgentQueueStateV1) -> AgentQueueState {
        var migratedInFlight = false
        let tasks = legacy.tasks.map { legacyTask in
            var task = legacyTask
            switch task.status {
            case .dispatching, .dispatched, .awaitingReport, .retrying:
                task.status = .blocked
                task.lastError = "Blocked during Agent Queue protocol migration; inspect before retrying."
                migratedInFlight = true
            case .queued, .completed, .blocked, .failed, .cancelled:
                break
            }
            return task
        }

        let plannerBinding = AgentQueueAgentBinding(
            bindingID: "legacy-planner-\(legacy.queue.plannerSurfaceID.uuidString.lowercased())",
            agentID: AgentQueueAgentID.planner,
            role: .planner,
            workspaceID: legacy.queue.workspaceID,
            paneID: nil,
            surfaceID: legacy.queue.plannerSurfaceID,
            readiness: .notReady,
            preparedAt: legacy.queue.updatedAt,
            readyDeadline: nil,
            readyAt: nil,
            lastSeenAt: nil,
            observedSessionID: nil
        )
        let workerBindings = legacy.workers.map { worker in
            AgentQueueAgentBinding(
                bindingID: "legacy-\(worker.id)-\(worker.surfaceID.uuidString.lowercased())",
                agentID: worker.id,
                role: .worker,
                workspaceID: worker.workspaceID,
                paneID: worker.paneID,
                surfaceID: worker.surfaceID,
                readiness: .notReady,
                preparedAt: legacy.queue.updatedAt,
                readyDeadline: nil,
                readyAt: nil,
                lastSeenAt: worker.lastSeenAt,
                observedSessionID: nil
            )
        }
        let workers = legacy.workers.map { worker in
            var worker = worker
            worker.bindingID = nil
            worker.status = .offline
            worker.currentTaskID = nil
            return worker
        }
        var queue = AgentQueue(
            id: legacy.queue.id,
            workspaceID: legacy.queue.workspaceID,
            status: legacy.queue.status,
            createdAt: legacy.queue.createdAt,
            updatedAt: legacy.queue.updatedAt
        )
        if migratedInFlight || plannerBinding.readiness != .ready {
            queue.status = .paused
        }
        let preparation = legacy.preparation.map { previous in
            AgentQueuePreparationState(
                configuration: previous.configuration,
                phase: .notPrepared,
                completedWorkerCount: 0,
                errorMessage: nil,
                records: previous.records.map { record in
                    var record = record
                    record.phase = .notPrepared
                    record.errorMessage = nil
                    return record
                },
                desiredRoleSkillFingerprints: [:]
            )
        }

        return AgentQueueState(
            schemaVersion: AgentQueueState.currentSchemaVersion,
            revision: 0,
            queue: queue,
            tasks: tasks,
            workers: workers,
            bindings: [plannerBinding] + workerBindings,
            submissions: [],
            reports: [],
            events: legacy.events,
            preparation: preparation
        )
    }
}

private struct SchemaVersionProbe: Decodable {
    var schemaVersion: Int?
}

private struct LegacyAgentQueueStateV1: Decodable {
    var queue: LegacyAgentQueueV1
    var tasks: [AgentTask]
    var workers: [AgentWorker]
    var events: [AgentQueueLogEvent]
    var preparation: AgentQueuePreparationState?
}

private struct LegacyAgentQueueV1: Decodable {
    var id: String
    var workspaceID: UUID
    var plannerSurfaceID: UUID
    var status: AgentQueueStatus
    var createdAt: Date
    var updatedAt: Date
}
