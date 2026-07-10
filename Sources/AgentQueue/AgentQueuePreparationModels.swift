import Foundation

struct AgentQueueSkillSelection: Identifiable, Codable, Equatable, Sendable {
    var id: String { sourcePath }
    var name: String
    var sourcePath: String
    var invocation: String { "$\(name)" }
}

enum AgentQueueAgentID {
    static let planner = "planner"
    static let workerIDs = (0..<4).map { worker(index: $0) }

    static func worker(index: Int) -> String {
        "worker-\(index + 1)"
    }
}

struct AgentQueueAgentProfile: Codable, Equatable, Sendable {
    var id: String
    var additionalSkills: [AgentQueueSkillSelection]
    var rolePrompt: String

    static let planner = AgentQueueAgentProfile(
        id: AgentQueueAgentID.planner,
        additionalSkills: [],
        rolePrompt: ""
    )

    static let defaultWorkers = (0..<4).map { worker(index: $0) }

    static func worker(index: Int) -> AgentQueueAgentProfile {
        AgentQueueAgentProfile(
            id: AgentQueueAgentID.worker(index: index),
            additionalSkills: [],
            rolePrompt: ""
        )
    }

    func addingSkill(_ skill: AgentQueueSkillSelection) -> AgentQueueAgentProfile {
        let normalizedPath = AgentQueueSkillPath.normalize(skill.sourcePath)
        guard !additionalSkills.contains(where: {
            AgentQueueSkillPath.normalize($0.sourcePath) == normalizedPath
        }) else {
            return self
        }

        var copy = self
        copy.additionalSkills.append(skill)
        return copy
    }

    func removingSkill(sourcePath: String) -> AgentQueueAgentProfile {
        let normalizedPath = AgentQueueSkillPath.normalize(sourcePath)
        var copy = self
        copy.additionalSkills.removeAll {
            AgentQueueSkillPath.normalize($0.sourcePath) == normalizedPath
        }
        return copy
    }
}

struct AgentQueuePreparationConfiguration: Codable, Equatable, Sendable {
    var workerCount: Int
    var plannerProfile: AgentQueueAgentProfile
    var workerProfiles: [AgentQueueAgentProfile]

    init(
        workerCount: Int,
        plannerProfile: AgentQueueAgentProfile,
        workerProfiles: [AgentQueueAgentProfile]
    ) throws {
        guard (1...4).contains(workerCount) else {
            throw AgentQueuePreparationError.invalidWorkerCount(workerCount)
        }
        guard plannerProfile.id == AgentQueueAgentID.planner,
              workerProfiles.map(\.id) == AgentQueueAgentID.workerIDs,
              Self.hasUniqueSkillPaths(plannerProfile),
              workerProfiles.allSatisfy(Self.hasUniqueSkillPaths) else {
            throw AgentQueuePreparationError.invalidAgentProfiles
        }

        self.workerCount = workerCount
        self.plannerProfile = plannerProfile
        self.workerProfiles = workerProfiles
    }

    init(workerCount: Int, additionalSkill: AgentQueueSkillSelection?) throws {
        let workerProfiles = AgentQueueAgentProfile.defaultWorkers.map { profile in
            guard let additionalSkill else { return profile }
            return profile.addingSkill(additionalSkill)
        }
        try self.init(
            workerCount: workerCount,
            plannerProfile: .planner,
            workerProfiles: workerProfiles
        )
    }

    static let defaultConfiguration = try! AgentQueuePreparationConfiguration(
        workerCount: 1,
        plannerProfile: .planner,
        workerProfiles: AgentQueueAgentProfile.defaultWorkers
    )

    var activeAgentIDs: [String] {
        [AgentQueueAgentID.planner] + Array(AgentQueueAgentID.workerIDs.prefix(workerCount))
    }

    var additionalSkill: AgentQueueSkillSelection? {
        workerProfiles.first?.additionalSkills.first
    }

    func profile(id: String) -> AgentQueueAgentProfile? {
        if id == AgentQueueAgentID.planner {
            return plannerProfile
        }
        return workerProfiles.first(where: { $0.id == id })
    }

    func replacingProfile(_ profile: AgentQueueAgentProfile) throws -> AgentQueuePreparationConfiguration {
        if profile.id == AgentQueueAgentID.planner {
            return try AgentQueuePreparationConfiguration(
                workerCount: workerCount,
                plannerProfile: profile,
                workerProfiles: workerProfiles
            )
        }
        guard let index = workerProfiles.firstIndex(where: { $0.id == profile.id }) else {
            throw AgentQueuePreparationError.invalidAgentProfiles
        }
        var updatedWorkers = workerProfiles
        updatedWorkers[index] = profile
        return try AgentQueuePreparationConfiguration(
            workerCount: workerCount,
            plannerProfile: plannerProfile,
            workerProfiles: updatedWorkers
        )
    }

    func replacingWorkerCount(_ workerCount: Int) throws -> AgentQueuePreparationConfiguration {
        try AgentQueuePreparationConfiguration(
            workerCount: workerCount,
            plannerProfile: plannerProfile,
            workerProfiles: workerProfiles
        )
    }

    private enum CodingKeys: String, CodingKey {
        case workerCount
        case plannerProfile
        case workerProfiles
        case additionalSkill
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let workerCount = try container.decode(Int.self, forKey: .workerCount)
        if container.contains(.plannerProfile) || container.contains(.workerProfiles) {
            try self.init(
                workerCount: workerCount,
                plannerProfile: container.decode(AgentQueueAgentProfile.self, forKey: .plannerProfile),
                workerProfiles: container.decode([AgentQueueAgentProfile].self, forKey: .workerProfiles)
            )
        } else {
            try self.init(
                workerCount: workerCount,
                additionalSkill: container.decodeIfPresent(
                    AgentQueueSkillSelection.self,
                    forKey: .additionalSkill
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workerCount, forKey: .workerCount)
        try container.encode(plannerProfile, forKey: .plannerProfile)
        try container.encode(workerProfiles, forKey: .workerProfiles)
    }

    private static func hasUniqueSkillPaths(_ profile: AgentQueueAgentProfile) -> Bool {
        let paths = profile.additionalSkills.map { AgentQueueSkillPath.normalize($0.sourcePath) }
        return Set(paths).count == paths.count
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

enum AgentQueueAgentPreparationPhase: String, Codable, Equatable, Sendable {
    case notPrepared
    case preparing
    case ready
    case failed
}

struct AgentQueueAgentPreparationRecord: Identifiable, Codable, Equatable, Sendable {
    var id: String { agentID }
    var agentID: String
    var surfaceID: UUID?
    var appliedProfileFingerprint: String?
    var appliedRoleSkillFingerprint: String?
    var phase: AgentQueueAgentPreparationPhase
    var errorMessage: String?
}

struct AgentQueuePreparationState: Codable, Equatable, Sendable {
    var configuration: AgentQueuePreparationConfiguration
    var phase: AgentQueuePreparationPhase
    var completedWorkerCount: Int
    var errorMessage: String?
    var records: [AgentQueueAgentPreparationRecord]
    var desiredRoleSkillFingerprints: [String: String]

    init(
        configuration: AgentQueuePreparationConfiguration,
        phase: AgentQueuePreparationPhase,
        completedWorkerCount: Int,
        errorMessage: String?,
        records: [AgentQueueAgentPreparationRecord] = [],
        desiredRoleSkillFingerprints: [String: String] = [:]
    ) {
        self.configuration = configuration
        self.phase = phase
        self.completedWorkerCount = completedWorkerCount
        self.errorMessage = errorMessage
        self.records = records
        self.desiredRoleSkillFingerprints = desiredRoleSkillFingerprints
    }

    func record(agentID: String) -> AgentQueueAgentPreparationRecord? {
        records.first(where: { $0.agentID == agentID })
    }

    func replacingRecord(
        _ record: AgentQueueAgentPreparationRecord
    ) -> AgentQueuePreparationState {
        var copy = self
        if let index = copy.records.firstIndex(where: { $0.agentID == record.agentID }) {
            copy.records[index] = record
        } else {
            copy.records.append(record)
        }
        return copy
    }

    func isReady(agentID: String) -> Bool {
        guard let profile = configuration.profile(id: agentID),
              let record = record(agentID: agentID),
              record.phase == .ready,
              record.surfaceID != nil,
              record.appliedProfileFingerprint == AgentQueueProfileFingerprint.make(profile) else {
            return false
        }

        let role = agentID == AgentQueueAgentID.planner
            ? AgentQueueRoleSkill.planner
            : AgentQueueRoleSkill.worker
        guard agentID == AgentQueueAgentID.planner || AgentQueueAgentID.workerIDs.contains(agentID),
              let desiredRoleFingerprint = desiredRoleSkillFingerprints[role.rawValue] else {
            return false
        }
        return record.appliedRoleSkillFingerprint == desiredRoleFingerprint
    }

    func dirtyAgentIDs() -> [String] {
        configuration.activeAgentIDs.filter { !isReady(agentID: $0) }
    }

    private enum CodingKeys: String, CodingKey {
        case configuration
        case phase
        case completedWorkerCount
        case errorMessage
        case records
        case desiredRoleSkillFingerprints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            configuration: try container.decode(
                AgentQueuePreparationConfiguration.self,
                forKey: .configuration
            ),
            phase: try container.decode(AgentQueuePreparationPhase.self, forKey: .phase),
            completedWorkerCount: try container.decode(Int.self, forKey: .completedWorkerCount),
            errorMessage: try container.decodeIfPresent(String.self, forKey: .errorMessage),
            records: try container.decodeIfPresent(
                [AgentQueueAgentPreparationRecord].self,
                forKey: .records
            ) ?? [],
            desiredRoleSkillFingerprints: try container.decodeIfPresent(
                [String: String].self,
                forKey: .desiredRoleSkillFingerprints
            ) ?? [:]
        )
    }
}

enum AgentQueuePreparationError: Error, Equatable, Sendable {
    case invalidWorkerCount(Int)
    case invalidAgentProfiles
    case activeWorkerWouldClose(UUID)
    case plannerUnavailable
    case plannerBusy
    case codexReadinessTimedOut(UUID)
    case skillInstallationFailed(String)
}

struct AgentQueueWorkerSlot: Codable, Equatable, Sendable {
    var agentID: String
    var surfaceID: UUID
}

struct AgentQueueWorkerReconciliationPlan: Equatable, Sendable {
    var keep: [AgentQueueWorkerSlot]
    var createAgentIDs: [String]
    var close: [AgentQueueWorkerSlot]
}

enum AgentQueueWorkerReconciler {
    static func plan(
        existing: [AgentQueueWorkerSlot],
        requestedCount: Int,
        activeWorkerAgentIDs: Set<String>
    ) throws -> AgentQueueWorkerReconciliationPlan {
        guard (1...4).contains(requestedCount) else {
            throw AgentQueuePreparationError.invalidWorkerCount(requestedCount)
        }

        let requestedAgentIDs = Array(AgentQueueAgentID.workerIDs.prefix(requestedCount))
        var remaining = existing
        var keep: [AgentQueueWorkerSlot] = []
        var createAgentIDs: [String] = []

        for agentID in requestedAgentIDs {
            if let index = remaining.firstIndex(where: { $0.agentID == agentID }) {
                keep.append(remaining.remove(at: index))
            } else {
                createAgentIDs.append(agentID)
            }
        }

        let close = remaining.sorted(by: slotOrder)
        if let activeSlot = close.first(where: { activeWorkerAgentIDs.contains($0.agentID) }) {
            throw AgentQueuePreparationError.activeWorkerWouldClose(activeSlot.surfaceID)
        }

        return AgentQueueWorkerReconciliationPlan(
            keep: keep,
            createAgentIDs: createAgentIDs,
            close: close
        )
    }

    private static func slotOrder(_ lhs: AgentQueueWorkerSlot, _ rhs: AgentQueueWorkerSlot) -> Bool {
        let lhsIndex = AgentQueueAgentID.workerIDs.firstIndex(of: lhs.agentID) ?? Int.max
        let rhsIndex = AgentQueueAgentID.workerIDs.firstIndex(of: rhs.agentID) ?? Int.max
        if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
        if lhs.agentID != rhs.agentID { return lhs.agentID < rhs.agentID }
        return lhs.surfaceID.uuidString < rhs.surfaceID.uuidString
    }
}
