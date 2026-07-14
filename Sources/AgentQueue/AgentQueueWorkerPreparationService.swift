import Foundation

struct AgentQueueAgentPreparationFailure: Equatable, Sendable {
    var agentID: String
    var surfaceID: UUID?
    var message: String
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
        activeWorkerAgentIDs: Set<String>
    ) async throws -> AgentQueuePreparedTopology {
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
        topology _: AgentQueuePreparedTopology,
        bindings: [AgentQueueAgentBinding],
        configuration: AgentQueuePreparationConfiguration
    ) async -> [AgentQueueAgentPreparationFailure] {
        var failures: [AgentQueueAgentPreparationFailure] = []
        for binding in bindings {
            guard let surfaceID = binding.surfaceID,
                  let profile = configuration.profile(id: binding.agentID) else {
                failures.append(
                    AgentQueueAgentPreparationFailure(
                        agentID: binding.agentID,
                        surfaceID: binding.surfaceID,
                        message: missingBindingMessage(agentID: binding.agentID)
                    )
                )
                continue
            }
            do {
                let prompt = instructionBuilder.bootstrap(
                    agentID: binding.agentID,
                    role: binding.role,
                    bindingID: binding.bindingID,
                    profile: profile
                )
                let submittedAtLaunch = try await prepareBoundAgent(
                    agentID: binding.agentID,
                    bindingID: binding.bindingID,
                    surfaceID: surfaceID,
                    initialPrompt: prompt
                )
                if !submittedAtLaunch {
                    try await driver.submitText(prompt, to: surfaceID)
                }
            } catch {
                failures.append(
                    AgentQueueAgentPreparationFailure(
                        agentID: binding.agentID,
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
        surfaceID: UUID,
        initialPrompt: String
    ) async throws -> Bool {
        guard driver.isTerminalSurface(surfaceID) else {
            throw AgentQueuePaneAdapterError.surfaceNotTerminal(surfaceID)
        }
        switch await driver.codexReadiness(surfaceID: surfaceID) {
        case .idle:
            return false
        case .busy, .starting:
            try await waitForIdle(surfaceID: surfaceID)
            return false
        case .absent:
            if driver.shellActivity(surfaceID: surfaceID) != .promptIdle {
                try await waitForShellPrompt(surfaceID: surfaceID)
            }
            try await driver.submitShellCommand(
                instructionBuilder.launchCommand(
                    agentID: agentID,
                    bindingID: bindingID,
                    initialPrompt: initialPrompt
                ),
                to: surfaceID
            )
            return true
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

    private func missingBindingMessage(agentID: String) -> String {
        String.localizedStringWithFormat(
            String(
                localized: "agentQueue.preparation.error.missingBinding",
                defaultValue: "Missing Agent Queue binding surface or profile: %@"
            ),
            agentID
        )
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
