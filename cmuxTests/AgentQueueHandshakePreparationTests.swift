import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Agent Queue binding handshake preparation")
struct AgentQueueHandshakePreparationTests {
    @Test
    func bootstrapStartsWithGenerationBoundReadyCommand() {
        let profile = AgentQueueAgentProfile(
            id: "worker-1",
            additionalSkills: [
                AgentQueueSkillSelection(name: "careful", sourcePath: "/tmp/careful/SKILL.md"),
            ],
            rolePrompt: "Inspect first. Preserve \\ and \"quotes\"."
        )

        let prompt = AgentQueueCLIInstructionBuilder().bootstrap(
            agentID: "worker-1",
            role: .worker,
            bindingID: "11111111-2222-3333-4444-555555555555",
            profile: profile
        )

        #expect(prompt.hasPrefix(
            "cmux agent-queue agent ready --agent worker-1 --role worker " +
                "--binding 11111111-2222-3333-4444-555555555555\n"
        ))
        #expect(prompt.contains("$cmux-agent-queue-worker $careful"))
        #expect(prompt.contains("Inspect first. Preserve \\ and \"quotes\"."))
    }

    @Test
    func launchCommandPreservesCodexExitAndShellEscapesOfflineIdentity() {
        let command = AgentQueueCLIInstructionBuilder().launchCommand(
            agentID: "worker-'one",
            bindingID: "binding-'one"
        )

        #expect(command.contains("CMUX_BUNDLED_CLI_PATH"))
        #expect(command.contains("codex"))
        #expect(command.contains("status=$?"))
        #expect(command.contains("agent offline"))
        #expect(command.contains("'worker-'\"'\"'one'"))
        #expect(command.contains("'binding-'\"'\"'one'"))
        #expect(command.hasSuffix("exit \"$status\""))
    }

    @Test
    func readinessUsesProcessStateAndShellActivityOnly() {
        let classifier = AgentQueueCodexReadinessClassifier()

        #expect(classifier.classify(observedState: .idle, shellActivity: .commandRunning) == .idle)
        #expect(classifier.classify(observedState: .working, shellActivity: .promptIdle) == .busy)
        #expect(classifier.classify(observedState: nil, shellActivity: .commandRunning) == .starting)
        #expect(classifier.classify(observedState: nil, shellActivity: .promptIdle) == .absent)
    }

    @Test
    func topologyReductionUnregistersExtraSlotWithoutClosingItsPane() async throws {
        let planner = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let first = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let second = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let driver = HandshakePreparationDriver(
            terminalSurfaceIDs: [planner, first, second]
        )
        let service = AgentQueueWorkerPreparationService(driver: driver)

        let topology = try await service.prepareTopology(
            configuration: .defaultConfiguration,
            plannerSurfaceID: planner,
            existingWorkerSlots: [
                AgentQueueWorkerSlot(agentID: "worker-1", surfaceID: first),
                AgentQueueWorkerSlot(agentID: "worker-2", surfaceID: second),
            ],
            activeWorkerAgentIDs: []
        )

        #expect(topology.workerSlots == [AgentQueueWorkerSlot(agentID: "worker-1", surfaceID: first)])
        #expect(driver.closedSurfaceIDs.isEmpty)
    }

    @Test
    func bootstrapLaunchesWrappedCodexThenSubmitsReadyPrompt() async throws {
        let planner = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let worker = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let driver = HandshakePreparationDriver(terminalSurfaceIDs: [planner, worker])
        driver.readinessBySurface[planner] = [.idle]
        driver.readinessBySurface[worker] = [.absent, .idle]
        driver.shellActivityBySurface[worker] = .promptIdle
        let service = AgentQueueWorkerPreparationService(
            driver: driver,
            sleep: { _ in await Task.yield() }
        )
        let now = Date(timeIntervalSince1970: 1_784_006_400)
        let topology = AgentQueuePreparedTopology(
            plannerSurfaceID: planner,
            workerSlots: [AgentQueueWorkerSlot(agentID: "worker-1", surfaceID: worker)],
            workingDirectory: "/tmp/repo"
        )
        let bindings = [
            AgentQueueAgentBinding(
                bindingID: "binding-planner-1",
                agentID: "planner",
                role: .planner,
                workspaceID: UUID(),
                paneID: planner,
                surfaceID: planner,
                readiness: .pending,
                preparedAt: now,
                readyDeadline: now.addingTimeInterval(30),
                readyAt: nil,
                lastSeenAt: nil,
                observedSessionID: nil
            ),
            AgentQueueAgentBinding(
                bindingID: "binding-worker-1",
                agentID: "worker-1",
                role: .worker,
                workspaceID: UUID(),
                paneID: worker,
                surfaceID: worker,
                readiness: .pending,
                preparedAt: now,
                readyDeadline: now.addingTimeInterval(30),
                readyAt: nil,
                lastSeenAt: nil,
                observedSessionID: nil
            ),
        ]

        let failures = await service.bootstrap(
            topology: topology,
            bindings: bindings,
            configuration: .defaultConfiguration
        )

        #expect(failures.isEmpty)
        #expect(driver.shellCommands.count == 1)
        #expect(driver.shellCommands[0].surfaceID == worker)
        #expect(driver.shellCommands[0].text.contains("agent offline"))
        #expect(driver.prompts.count == 2)
        #expect(driver.prompts.allSatisfy { $0.text.hasPrefix("cmux agent-queue agent ready") })
    }
}

@MainActor
private final class HandshakePreparationDriver: AgentQueueWorkspaceDriving {
    let workingDirectory = "/tmp/repo"
    var terminalSurfaceIDs: Set<UUID>
    var shellActivityBySurface: [UUID: AgentQueueShellActivity] = [:]
    var readinessBySurface: [UUID: [AgentQueueCodexReadiness]] = [:]
    var createdSurfaceID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private(set) var closedSurfaceIDs: [UUID] = []
    private(set) var shellCommands: [(surfaceID: UUID, text: String)] = []
    private(set) var prompts: [(surfaceID: UUID, text: String)] = []

    init(terminalSurfaceIDs: Set<UUID>) {
        self.terminalSurfaceIDs = terminalSurfaceIDs
    }

    func isTerminalSurface(_ surfaceID: UUID) -> Bool {
        terminalSurfaceIDs.contains(surfaceID)
    }

    func shellActivity(surfaceID: UUID) -> AgentQueueShellActivity {
        shellActivityBySurface[surfaceID] ?? .promptIdle
    }

    func createWorkerSplit(_ request: AgentQueueWorkerSplitRequest) -> UUID? {
        terminalSurfaceIDs.insert(createdSurfaceID)
        return createdSurfaceID
    }

    func closeWorkerSurface(_ surfaceID: UUID) -> Bool {
        closedSurfaceIDs.append(surfaceID)
        return true
    }

    func codexReadiness(surfaceID: UUID) async -> AgentQueueCodexReadiness {
        guard var values = readinessBySurface[surfaceID], !values.isEmpty else { return .idle }
        let value = values.removeFirst()
        readinessBySurface[surfaceID] = values
        return value
    }

    func submitText(_ text: String, to surfaceID: UUID) async throws {
        prompts.append((surfaceID, text))
    }

    func submitShellCommand(_ command: String, to surfaceID: UUID) async throws {
        shellCommands.append((surfaceID, command))
    }
}
