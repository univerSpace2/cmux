import Foundation

struct AgentQueuePreparedAgent: Equatable, Sendable {
    var agentID: String
    var surfaceID: UUID
}

struct AgentQueueAgentPreparationFailure: Equatable, Sendable {
    var agentID: String
    var surfaceID: UUID?
    var message: String
}

struct AgentQueuePreparationProgress: Equatable, Sendable {
    var agentID: String?
    var phase: AgentQueuePreparationPhase
    var completedWorkerCount: Int
}

struct AgentQueuePreparedWorkspace: Equatable, Sendable {
    var plannerSurfaceID: UUID
    var workerSlots: [AgentQueueWorkerSlot]
    var workingDirectory: String
    var preparedAgents: [AgentQueuePreparedAgent]
    var failures: [AgentQueueAgentPreparationFailure]
}

struct AgentQueuePreparedTopology: Equatable, Sendable {
    var plannerSurfaceID: UUID
    var workerSlots: [AgentQueueWorkerSlot]
    var workingDirectory: String
}

enum AgentQueueWorkerSplitDirection: Equatable, Sendable {
    case right
}

struct AgentQueueWorkerSplitRequest: Equatable, Sendable {
    var sourceSurfaceID: UUID
    var direction: AgentQueueWorkerSplitDirection
    var focus: Bool
    var workingDirectory: String
    var initialCommand: String
}

@MainActor
protocol AgentQueueWorkspaceDriving: AnyObject {
    var workingDirectory: String { get }

    func isTerminalSurface(_ surfaceID: UUID) -> Bool
    func shellActivity(surfaceID: UUID) -> AgentQueueShellActivity
    func createWorkerSplit(_ request: AgentQueueWorkerSplitRequest) -> UUID?
    func closeWorkerSurface(_ surfaceID: UUID) -> Bool
    func codexReadiness(surfaceID: UUID) async -> AgentQueueCodexReadiness
    func submitText(_ text: String, to surfaceID: UUID) async throws
    func submitShellCommand(_ command: String, to surfaceID: UUID) async throws
}

@MainActor
protocol AgentQueueWorkerPreparing: AnyObject {
    func prepareTopology(
        configuration: AgentQueuePreparationConfiguration,
        plannerSurfaceID: UUID,
        existingWorkerSlots: [AgentQueueWorkerSlot],
        activeWorkerAgentIDs: Set<String>
    ) async throws -> AgentQueuePreparedTopology

    func bootstrap(
        topology: AgentQueuePreparedTopology,
        bindings: [AgentQueueAgentBinding],
        configuration: AgentQueuePreparationConfiguration
    ) async -> [AgentQueueAgentPreparationFailure]

    func prepare(
        configuration: AgentQueuePreparationConfiguration,
        plannerSurfaceID: UUID,
        existingWorkerSlots: [AgentQueueWorkerSlot],
        activeWorkerAgentIDs: Set<String>,
        agentIDsToPrepare: Set<String>,
        progress: @escaping @MainActor (AgentQueuePreparationProgress) -> Void
    ) async throws -> AgentQueuePreparedWorkspace
}

extension AgentQueueWorkerPreparing {
    func prepareTopology(
        configuration: AgentQueuePreparationConfiguration,
        plannerSurfaceID: UUID,
        existingWorkerSlots: [AgentQueueWorkerSlot],
        activeWorkerAgentIDs _: Set<String>
    ) async throws -> AgentQueuePreparedTopology {
        let requestedIDs = Array(AgentQueueAgentID.workerIDs.prefix(configuration.workerCount))
        let slots = requestedIDs.compactMap { agentID in
            existingWorkerSlots.first(where: { $0.agentID == agentID })
        }
        guard slots.count == requestedIDs.count else {
            throw AgentQueuePreparationError.plannerUnavailable
        }
        return AgentQueuePreparedTopology(
            plannerSurfaceID: plannerSurfaceID,
            workerSlots: slots,
            workingDirectory: ""
        )
    }

    func bootstrap(
        topology _: AgentQueuePreparedTopology,
        bindings _: [AgentQueueAgentBinding],
        configuration _: AgentQueuePreparationConfiguration
    ) async -> [AgentQueueAgentPreparationFailure] {
        []
    }
}

@MainActor
final class AgentQueueWorkerPreparationService: AgentQueueWorkerPreparing {
    private let driver: AgentQueueWorkspaceDriving
    private let readinessTimeout: Duration
    private let pollInterval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let instructionBuilder: AgentQueueCLIInstructionBuilder

    init(
        driver: AgentQueueWorkspaceDriving,
        readinessTimeout: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(100),
        instructionBuilder: AgentQueueCLIInstructionBuilder = .init(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.driver = driver
        self.readinessTimeout = readinessTimeout
        self.pollInterval = pollInterval
        self.instructionBuilder = instructionBuilder
        self.sleep = sleep
    }

    convenience init(workspace: Workspace, tabManager: TabManager) {
        self.init(driver: AppAgentQueueWorkspaceDriver(workspace: workspace, tabManager: tabManager))
    }

    func prepareTopology(
        configuration: AgentQueuePreparationConfiguration,
        plannerSurfaceID: UUID,
        existingWorkerSlots: [AgentQueueWorkerSlot],
        activeWorkerAgentIDs _: Set<String>
    ) async throws -> AgentQueuePreparedTopology {
        let plan = try AgentQueueWorkerReconciler.plan(
            existing: existingWorkerSlots,
            requestedCount: configuration.workerCount,
            activeWorkerAgentIDs: []
        )
        guard driver.isTerminalSurface(plannerSurfaceID) else {
            throw AgentQueuePreparationError.plannerUnavailable
        }
        let workingDirectory = driver.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workingDirectory.isEmpty else {
            throw AgentQueuePreparationError.plannerUnavailable
        }

        var workerSlots = plan.keep
        for agentID in plan.createAgentIDs {
            let request = AgentQueueWorkerSplitRequest(
                sourceSurfaceID: plannerSurfaceID,
                direction: .right,
                focus: false,
                workingDirectory: workingDirectory,
                initialCommand: ""
            )
            guard let surfaceID = driver.createWorkerSplit(request) else {
                throw AgentQueuePreparationError.plannerUnavailable
            }
            workerSlots.append(AgentQueueWorkerSlot(agentID: agentID, surfaceID: surfaceID))
        }
        workerSlots.sort { lhs, rhs in
            let lhsIndex = AgentQueueAgentID.workerIDs.firstIndex(of: lhs.agentID) ?? Int.max
            let rhsIndex = AgentQueueAgentID.workerIDs.firstIndex(of: rhs.agentID) ?? Int.max
            return lhsIndex < rhsIndex
        }
        return AgentQueuePreparedTopology(
            plannerSurfaceID: plannerSurfaceID,
            workerSlots: workerSlots,
            workingDirectory: workingDirectory
        )
    }

    func bootstrap(
        topology: AgentQueuePreparedTopology,
        bindings: [AgentQueueAgentBinding],
        configuration: AgentQueuePreparationConfiguration
    ) async -> [AgentQueueAgentPreparationFailure] {
        var failures: [AgentQueueAgentPreparationFailure] = []
        for agentID in configuration.activeAgentIDs {
            guard let binding = bindings.first(where: { $0.agentID == agentID }),
                  let surfaceID = binding.surfaceID,
                  let profile = configuration.profile(id: agentID) else {
                failures.append(
                    AgentQueueAgentPreparationFailure(
                        agentID: agentID,
                        surfaceID: bindings.first(where: { $0.agentID == agentID })?.surfaceID,
                        message: "Missing Agent Queue binding, surface, or profile for \(agentID)."
                    )
                )
                continue
            }
            do {
                try await prepareBoundAgent(
                    agentID: agentID,
                    bindingID: binding.bindingID,
                    surfaceID: surfaceID
                )
                let prompt = instructionBuilder.bootstrap(
                    agentID: agentID,
                    role: binding.role,
                    bindingID: binding.bindingID,
                    profile: profile
                )
                try await driver.submitText(prompt, to: surfaceID)
            } catch {
                failures.append(
                    AgentQueueAgentPreparationFailure(
                        agentID: agentID,
                        surfaceID: surfaceID,
                        message: error.localizedDescription
                    )
                )
            }
        }
        return failures
    }

    private func prepareBoundAgent(
        agentID: String,
        bindingID: String,
        surfaceID: UUID
    ) async throws {
        guard driver.isTerminalSurface(surfaceID) else {
            throw AgentQueuePaneAdapterError.surfaceNotTerminal(surfaceID)
        }
        switch await driver.codexReadiness(surfaceID: surfaceID) {
        case .idle:
            return
        case .busy, .starting:
            try await waitForIdle(surfaceID: surfaceID)
        case .absent:
            if driver.shellActivity(surfaceID: surfaceID) != .promptIdle {
                try await waitForShellPrompt(surfaceID: surfaceID)
            }
            try await driver.submitShellCommand(
                instructionBuilder.launchCommand(agentID: agentID, bindingID: bindingID),
                to: surfaceID
            )
            try await waitForIdle(surfaceID: surfaceID)
        }
    }

    func prepare(
        configuration: AgentQueuePreparationConfiguration,
        plannerSurfaceID: UUID,
        existingWorkerSlots: [AgentQueueWorkerSlot],
        activeWorkerAgentIDs: Set<String>,
        agentIDsToPrepare: Set<String>,
        progress: @escaping @MainActor (AgentQueuePreparationProgress) -> Void
    ) async throws -> AgentQueuePreparedWorkspace {
        let plan = try AgentQueueWorkerReconciler.plan(
            existing: existingWorkerSlots,
            requestedCount: configuration.workerCount,
            activeWorkerAgentIDs: activeWorkerAgentIDs
        )
        guard driver.isTerminalSurface(plannerSurfaceID) else {
            throw AgentQueuePreparationError.plannerUnavailable
        }
        let workingDirectory = driver.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !workingDirectory.isEmpty else {
            throw AgentQueuePreparationError.plannerUnavailable
        }

        for slot in plan.close {
            guard driver.closeWorkerSurface(slot.surfaceID) else {
                throw AgentQueuePaneAdapterError.surfaceUnavailable(slot.surfaceID)
            }
        }

        var workerSlots = plan.keep
        var newlyCreatedSurfaceIDs: Set<UUID> = []
        for agentID in plan.createAgentIDs {
            let request = AgentQueueWorkerSplitRequest(
                sourceSurfaceID: plannerSurfaceID,
                direction: .right,
                focus: false,
                workingDirectory: workingDirectory,
                initialCommand: ""
            )
            guard let surfaceID = driver.createWorkerSplit(request) else {
                throw AgentQueuePreparationError.plannerUnavailable
            }
            workerSlots.append(AgentQueueWorkerSlot(agentID: agentID, surfaceID: surfaceID))
            newlyCreatedSurfaceIDs.insert(surfaceID)
        }
        workerSlots.sort { lhs, rhs in
            let lhsIndex = AgentQueueAgentID.workerIDs.firstIndex(of: lhs.agentID) ?? Int.max
            let rhsIndex = AgentQueueAgentID.workerIDs.firstIndex(of: rhs.agentID) ?? Int.max
            return lhsIndex < rhsIndex
        }

        var preparedAgents: [AgentQueuePreparedAgent] = []
        var failures: [AgentQueueAgentPreparationFailure] = []
        var completedWorkerCount = 0
        let orderedAgentIDs = configuration.activeAgentIDs.filter(agentIDsToPrepare.contains)

        for agentID in orderedAgentIDs {
            let surfaceID: UUID?
            let role: AgentQueueRoleSkill
            if agentID == AgentQueueAgentID.planner {
                surfaceID = plannerSurfaceID
                role = .planner
            } else {
                surfaceID = workerSlots.first(where: { $0.agentID == agentID })?.surfaceID
                role = .worker
            }

            guard let surfaceID, let profile = configuration.profile(id: agentID) else {
                failures.append(
                    AgentQueueAgentPreparationFailure(
                        agentID: agentID,
                        surfaceID: surfaceID,
                        message: "Missing Agent Queue surface or profile for \(agentID)."
                    )
                )
                continue
            }

            do {
                progress(
                    AgentQueuePreparationProgress(
                        agentID: agentID,
                        phase: role == .planner ? .startingPlanner : .startingWorkers,
                        completedWorkerCount: completedWorkerCount
                    )
                )
                if role == .planner {
                    try await preparePlanner(surfaceID: surfaceID)
                } else {
                    try await prepareWorker(
                        surfaceID: surfaceID,
                        launchCodexAfterShellReady: newlyCreatedSurfaceIDs.contains(surfaceID)
                    )
                }

                progress(
                    AgentQueuePreparationProgress(
                        agentID: agentID,
                        phase: .applyingSkills,
                        completedWorkerCount: completedWorkerCount
                    )
                )
                try await submitPrompt(
                    AgentQueueSkillPromptBuilder.prompt(role: role, profile: profile),
                    to: surfaceID
                )
                progress(
                    AgentQueuePreparationProgress(
                        agentID: agentID,
                        phase: .waitingForIdle,
                        completedWorkerCount: completedWorkerCount
                    )
                )
                try await waitForIdle(surfaceID: surfaceID)
                preparedAgents.append(AgentQueuePreparedAgent(agentID: agentID, surfaceID: surfaceID))
                if role == .worker {
                    completedWorkerCount += 1
                }
                progress(
                    AgentQueuePreparationProgress(
                        agentID: agentID,
                        phase: .waitingForIdle,
                        completedWorkerCount: completedWorkerCount
                    )
                )
            } catch {
                failures.append(
                    AgentQueueAgentPreparationFailure(
                        agentID: agentID,
                        surfaceID: surfaceID,
                        message: error.localizedDescription
                    )
                )
            }
        }

        return AgentQueuePreparedWorkspace(
            plannerSurfaceID: plannerSurfaceID,
            workerSlots: workerSlots,
            workingDirectory: workingDirectory,
            preparedAgents: preparedAgents,
            failures: failures
        )
    }

    private func preparePlanner(surfaceID: UUID) async throws {
        switch await driver.codexReadiness(surfaceID: surfaceID) {
        case .idle:
            return
        case .busy:
            throw AgentQueuePreparationError.plannerBusy
        case .starting:
            try await waitForIdle(surfaceID: surfaceID)
        case .absent:
            guard driver.shellActivity(surfaceID: surfaceID) == .promptIdle else {
                throw AgentQueuePreparationError.plannerBusy
            }
            try await driver.submitShellCommand("codex", to: surfaceID)
            try await waitForIdle(surfaceID: surfaceID)
        }
    }

    private func prepareWorker(surfaceID: UUID, launchCodexAfterShellReady: Bool) async throws {
        guard driver.isTerminalSurface(surfaceID) else {
            throw AgentQueuePaneAdapterError.surfaceNotTerminal(surfaceID)
        }
        if launchCodexAfterShellReady {
            try await waitForShellPrompt(surfaceID: surfaceID)
            try await driver.submitShellCommand("codex", to: surfaceID)
            try await waitForIdle(surfaceID: surfaceID)
            return
        }
        switch await driver.codexReadiness(surfaceID: surfaceID) {
        case .idle:
            return
        case .busy, .starting:
            try await waitForIdle(surfaceID: surfaceID)
        case .absent:
            guard driver.shellActivity(surfaceID: surfaceID) == .promptIdle else {
                try await waitForIdle(surfaceID: surfaceID)
                return
            }
            try await driver.submitShellCommand("codex", to: surfaceID)
            try await waitForIdle(surfaceID: surfaceID)
        }
    }

    private func waitForShellPrompt(surfaceID: UUID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: readinessTimeout)

        while clock.now <= deadline {
            guard driver.isTerminalSurface(surfaceID) else {
                throw AgentQueuePaneAdapterError.surfaceUnavailable(surfaceID)
            }
            if driver.shellActivity(surfaceID: surfaceID) == .promptIdle {
                return
            }
            guard clock.now < deadline else { break }
            try await sleep(pollInterval)
        }
        throw AgentQueuePreparationError.codexReadinessTimedOut(surfaceID)
    }

    private func submitPrompt(_ text: String, to surfaceID: UUID) async throws {
        try await driver.submitText(text, to: surfaceID)
    }

    private func waitForIdle(surfaceID: UUID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: readinessTimeout)

        while clock.now <= deadline {
            if await driver.codexReadiness(surfaceID: surfaceID) == .idle {
                return
            }
            guard clock.now < deadline else { break }
            try await sleep(pollInterval)
        }
        throw AgentQueuePreparationError.codexReadinessTimedOut(surfaceID)
    }
}

@MainActor
final class AppAgentQueueWorkspaceDriver: AgentQueueWorkspaceDriving {
    private weak var workspace: Workspace?
    private weak var tabManager: TabManager?
    private let paneAdapter: AppAgentQueuePaneAdapter

    init(workspace: Workspace, tabManager: TabManager) {
        self.workspace = workspace
        self.tabManager = tabManager
        paneAdapter = AppAgentQueuePaneAdapter(tabManager: tabManager)
    }

    var workingDirectory: String {
        workspace?.currentDirectory ?? ""
    }

    func isTerminalSurface(_ surfaceID: UUID) -> Bool {
        workspace?.terminalPanel(for: surfaceID) != nil
    }

    func shellActivity(surfaceID: UUID) -> AgentQueueShellActivity {
        guard let state = workspace?.panelShellActivityStates[surfaceID] else { return .unknown }
        switch state {
        case .unknown:
            return .unknown
        case .promptIdle:
            return .promptIdle
        case .commandRunning:
            return .commandRunning
        }
    }

    func createWorkerSplit(_ request: AgentQueueWorkerSplitRequest) -> UUID? {
        guard request.direction == .right,
              let workspace,
              let tabManager else { return nil }
        return tabManager.newSplit(
            tabId: workspace.id,
            surfaceId: request.sourceSurfaceID,
            direction: .right,
            focus: request.focus,
            workingDirectory: request.workingDirectory,
            initialCommand: request.initialCommand
        )
    }

    func closeWorkerSurface(_ surfaceID: UUID) -> Bool {
        workspace?.closePanel(surfaceID, force: true) ?? false
    }

    func codexReadiness(surfaceID: UUID) async -> AgentQueueCodexReadiness {
        await paneAdapter.codexReadiness(surfaceID: surfaceID)
    }

    func submitText(_ text: String, to surfaceID: UUID) async throws {
        _ = try await paneAdapter.submitText(text, to: surfaceID)
    }

    func submitShellCommand(_ command: String, to surfaceID: UUID) async throws {
        _ = try await paneAdapter.submitShellCommand(command, to: surfaceID)
    }
}
