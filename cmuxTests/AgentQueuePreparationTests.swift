import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Agent Queue preparation")
struct AgentQueuePreparationTests {
    @Test
    func topologyAddsOnlyMissingWorkersWithoutFocusOrPaneClosure() async throws {
        let planner = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let first = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let second = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let driver = PreparationDriver(
            terminalSurfaceIDs: [planner, first],
            createdSurfaceIDs: [second]
        )
        let service = AgentQueueWorkerPreparationService(driver: driver)
        let configuration = try AgentQueuePreparationConfiguration(
            workerCount: 2,
            plannerProfile: .planner,
            workerProfiles: AgentQueueAgentProfile.defaultWorkers
        )

        let topology = try await service.prepareTopology(
            configuration: configuration,
            plannerSurfaceID: planner,
            existingWorkerSlots: [AgentQueueWorkerSlot(agentID: "worker-1", surfaceID: first)],
            activeWorkerAgentIDs: []
        )

        #expect(topology.workerSlots == [
            AgentQueueWorkerSlot(agentID: "worker-1", surfaceID: first),
            AgentQueueWorkerSlot(agentID: "worker-2", surfaceID: second),
        ])
        #expect(driver.splitRequests.count == 1)
        #expect(driver.splitRequests[0].focus == false)
        #expect(driver.splitRequests[0].initialCommand.isEmpty)
    }

    @Test
    func topologyReductionUnregistersRosterOnlyAndDoesNotTouchPane() async throws {
        let planner = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let first = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let second = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let driver = PreparationDriver(terminalSurfaceIDs: [planner, first, second])
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
        #expect(driver.splitRequests.isEmpty)
        #expect(driver.terminalSurfaceIDs.contains(second))
    }

    @Test
    func bootstrapUsesBoundLaunchWrapperAndReadyPrompt() async {
        let planner = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let worker = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let workspaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let driver = PreparationDriver(terminalSurfaceIDs: [planner, worker])
        driver.readinessBySurface[planner] = [.idle]
        driver.readinessBySurface[worker] = [.absent, .idle]
        let service = AgentQueueWorkerPreparationService(
            driver: driver,
            pollInterval: .zero,
            sleep: { _ in await Task.yield() }
        )
        let now = Date(timeIntervalSince1970: 1_784_006_400)
        let bindings = [
            binding("planner-binding", "planner", .planner, workspaceID, planner, now),
            binding("worker-binding", "worker-1", .worker, workspaceID, worker, now),
        ]

        let failures = await service.bootstrap(
            topology: AgentQueuePreparedTopology(
                plannerSurfaceID: planner,
                workerSlots: [AgentQueueWorkerSlot(agentID: "worker-1", surfaceID: worker)],
                workingDirectory: "/tmp/repo"
            ),
            bindings: bindings,
            configuration: .defaultConfiguration
        )

        #expect(failures.isEmpty)
        #expect(driver.shellCommands.count == 1)
        #expect(driver.shellCommands[0].text.contains("agent offline"))
        #expect(driver.prompts.count == 2)
        #expect(driver.prompts.allSatisfy { $0.text.hasPrefix("cmux agent-queue agent ready") })
    }

    private func binding(
        _ id: String,
        _ agentID: String,
        _ role: AgentQueueAgentRole,
        _ workspaceID: UUID,
        _ surfaceID: UUID,
        _ now: Date
    ) -> AgentQueueAgentBinding {
        AgentQueueAgentBinding(
            bindingID: id,
            agentID: agentID,
            role: role,
            workspaceID: workspaceID,
            paneID: surfaceID,
            surfaceID: surfaceID,
            readiness: .pending,
            preparedAt: now,
            readyDeadline: now.addingTimeInterval(30),
            readyAt: nil,
            lastSeenAt: nil,
            observedSessionID: nil
        )
    }
}

@MainActor
private final class PreparationDriver: AgentQueueWorkspaceDriving {
    let workingDirectory = "/tmp/repo"
    var terminalSurfaceIDs: Set<UUID>
    var shellActivityBySurface: [UUID: AgentQueueShellActivity] = [:]
    var readinessBySurface: [UUID: [AgentQueueCodexReadiness]] = [:]
    var createdSurfaceIDs: [UUID]
    private(set) var splitRequests: [AgentQueueWorkerSplitRequest] = []
    private(set) var shellCommands: [(surfaceID: UUID, text: String)] = []
    private(set) var prompts: [(surfaceID: UUID, text: String)] = []

    init(terminalSurfaceIDs: Set<UUID>, createdSurfaceIDs: [UUID] = []) {
        self.terminalSurfaceIDs = terminalSurfaceIDs
        self.createdSurfaceIDs = createdSurfaceIDs
    }

    func isTerminalSurface(_ surfaceID: UUID) -> Bool {
        terminalSurfaceIDs.contains(surfaceID)
    }

    func shellActivity(surfaceID: UUID) -> AgentQueueShellActivity {
        shellActivityBySurface[surfaceID] ?? .promptIdle
    }

    func createWorkerSplit(_ request: AgentQueueWorkerSplitRequest) -> UUID? {
        splitRequests.append(request)
        guard !createdSurfaceIDs.isEmpty else { return nil }
        let surfaceID = createdSurfaceIDs.removeFirst()
        terminalSurfaceIDs.insert(surfaceID)
        return surfaceID
    }

    func codexReadiness(surfaceID: UUID) async -> AgentQueueCodexReadiness {
        guard var values = readinessBySurface[surfaceID], !values.isEmpty else { return .idle }
        let next = values.removeFirst()
        readinessBySurface[surfaceID] = values
        return next
    }

    func submitText(_ text: String, to surfaceID: UUID) async throws {
        prompts.append((surfaceID, text))
    }

    func submitShellCommand(_ command: String, to surfaceID: UUID) async throws {
        shellCommands.append((surfaceID, command))
    }
}
