import Foundation

struct AgentQueueSkillSelection: Identifiable, Codable, Equatable, Sendable {
    var id: String { sourcePath }
    var name: String
    var sourcePath: String
    var invocation: String { "$\(name)" }
}

struct AgentQueuePreparationConfiguration: Codable, Equatable, Sendable {
    var workerCount: Int
    var additionalSkill: AgentQueueSkillSelection?

    init(workerCount: Int, additionalSkill: AgentQueueSkillSelection?) throws {
        guard (1...4).contains(workerCount) else {
            throw AgentQueuePreparationError.invalidWorkerCount(workerCount)
        }
        self.workerCount = workerCount
        self.additionalSkill = additionalSkill
    }

    static let defaultConfiguration = try! AgentQueuePreparationConfiguration(
        workerCount: 1,
        additionalSkill: nil
    )

    private enum CodingKeys: String, CodingKey {
        case workerCount
        case additionalSkill
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            workerCount: container.decode(Int.self, forKey: .workerCount),
            additionalSkill: container.decodeIfPresent(
                AgentQueueSkillSelection.self,
                forKey: .additionalSkill
            )
        )
    }
}

enum AgentQueuePreparationPhase: String, Codable, Equatable, Sendable {
    case notPrepared
    case checkingSkills
    case awaitingSkillConfirmation
    case startingPlanner
    case startingWorkers
    case applyingSkills
    case waitingForIdle
    case ready
    case failed
}

struct AgentQueuePreparationState: Codable, Equatable, Sendable {
    var configuration: AgentQueuePreparationConfiguration
    var phase: AgentQueuePreparationPhase
    var completedWorkerCount: Int
    var errorMessage: String?
}

enum AgentQueuePreparationError: Error, Equatable, Sendable {
    case invalidWorkerCount(Int)
    case activeWorkerWouldClose(UUID)
    case plannerUnavailable
    case plannerBusy
    case codexReadinessTimedOut(UUID)
    case skillInstallationFailed(String)
}

struct AgentQueueWorkerReconciliationPlan: Equatable, Sendable {
    var keep: [UUID]
    var createCount: Int
    var close: [UUID]
}

enum AgentQueueWorkerReconciler {
    static func plan(
        existingWorkerSurfaceIDs: [UUID],
        requestedCount: Int,
        activeWorkerSurfaceIDs: Set<UUID>
    ) throws -> AgentQueueWorkerReconciliationPlan {
        guard (1...4).contains(requestedCount) else {
            throw AgentQueuePreparationError.invalidWorkerCount(requestedCount)
        }

        let keep = Array(existingWorkerSurfaceIDs.prefix(requestedCount))
        let close = Array(existingWorkerSurfaceIDs.dropFirst(requestedCount))
        if let activeSurfaceID = close.first(where: activeWorkerSurfaceIDs.contains) {
            throw AgentQueuePreparationError.activeWorkerWouldClose(activeSurfaceID)
        }

        return AgentQueueWorkerReconciliationPlan(
            keep: keep,
            createCount: max(0, requestedCount - existingWorkerSurfaceIDs.count),
            close: close
        )
    }
}

