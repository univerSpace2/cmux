import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Agent Queue controller facade")
struct AgentQueueControllerTests {
    @Test
    func pauseResumeAndManualRemovalRouteThroughCoordinator() async throws {
        let fixture = ControllerFixture(prepared: true)
        await fixture.controller.start()

        fixture.controller.pause()
        await waitUntil { await fixture.coordinator.snapshot().queue.status == .paused }
        fixture.controller.resume()
        await waitUntil { await fixture.coordinator.snapshot().queue.status == .running }

        fixture.controller.removeRegistration(agentID: "worker-1")
        await waitUntil {
            await !fixture.coordinator.snapshot().bindings.contains(where: {
                $0.agentID == "worker-1"
            })
        }

        let snapshot = await fixture.coordinator.snapshot()
        #expect(snapshot.queue.status == .running)
        #expect(snapshot.workers.isEmpty)
        fixture.controller.stop()
    }

    @Test
    func preparationCreatesGenerationBindingsAndWaitsForReadyHandshake() async throws {
        let fixture = ControllerFixture(prepared: false)
        fixture.preparer.onBootstrap = { bindings in
            for binding in bindings {
                _ = try await fixture.coordinator.markReady(
                    agentID: binding.agentID,
                    role: binding.role,
                    bindingID: binding.bindingID,
                    caller: AgentQueueCallerContext(
                        workspaceID: fixture.workspaceID,
                        surfaceID: binding.surfaceID!
                    )
                )
            }
        }
        await fixture.controller.start()

        await fixture.controller.prepareWorkers(allowSkillChanges: true)

        let snapshot = await fixture.coordinator.snapshot()
        #expect(snapshot.queue.status == .running)
        #expect(snapshot.bindings.count == 2)
        #expect(snapshot.bindings.allSatisfy { $0.readiness == .ready })
        #expect(snapshot.workers.count == 1)
        #expect(snapshot.workers[0].bindingID != nil)
        #expect(snapshot.workers[0].status == .idle)
        #expect(snapshot.preparation?.phase == .ready)
        #expect(snapshot.preparation?.completedWorkerCount == 1)
        #expect(fixture.preparer.bootstrapBindingIDs == Set(snapshot.bindings.map(\.bindingID)))
        fixture.controller.stop()
    }

    @Test
    func readyTimeoutUnregistersOnlyAndLeavesQueuePauseSticky() async throws {
        let fixture = ControllerFixture(prepared: false, status: .paused)
        await fixture.controller.start()

        await fixture.controller.prepareWorkers(allowSkillChanges: true)

        let snapshot = await fixture.coordinator.snapshot()
        #expect(snapshot.bindings.count == 1)
        #expect(snapshot.bindings[0].role == .planner)
        #expect(snapshot.bindings[0].readiness == .notReady)
        #expect(snapshot.bindings[0].surfaceID == nil)
        #expect(snapshot.workers.isEmpty)
        #expect(snapshot.queue.status == .paused)
        #expect(snapshot.preparation?.phase == .failed)
        #expect(snapshot.preparation?.errorMessage?.contains("handshake") == true)
        #expect(fixture.preparer.closeRequestCount == 0)
        fixture.controller.stop()
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<100 {
            if await predicate() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for controller command")
    }
}

@MainActor
private final class ControllerFixture {
    let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let plannerSurfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let workerSurfaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let coordinator: AgentQueueCoordinator
    let preparer: ControllerPreparer
    let controller: AgentQueueController

    init(prepared: Bool, status: AgentQueueStatus = .running) {
        let now = Date(timeIntervalSince1970: 1_784_006_400)
        let queue = AgentQueue(
            id: "queue-1",
            workspaceID: workspaceID,
            status: status,
            createdAt: now,
            updatedAt: now
        )
        let configuration = AgentQueuePreparationConfiguration.defaultConfiguration
        var workers: [AgentWorker] = []
        var bindings: [AgentQueueAgentBinding] = []
        var records: [AgentQueueAgentPreparationRecord] = []
        let plannerID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let workerID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        if prepared {
            let plannerBinding = Self.binding(
                id: "binding-planner",
                agentID: AgentQueueAgentID.planner,
                role: .planner,
                workspaceID: workspaceID,
                surfaceID: plannerSurfaceID,
                now: now
            )
            let workerBinding = Self.binding(
                id: "binding-worker",
                agentID: "worker-1",
                role: .worker,
                workspaceID: workspaceID,
                surfaceID: workerSurfaceID,
                now: now
            )
            bindings = [plannerBinding, workerBinding]
            workers = [
                AgentWorker(
                    id: "worker-1",
                    workspaceID: workspaceID,
                    paneID: workerSurfaceID,
                    surfaceID: workerSurfaceID,
                    label: "Worker 1",
                    enabled: true,
                    status: .idle,
                    currentTaskID: nil,
                    lastSeenAt: now,
                    bindingID: workerBinding.bindingID
                ),
            ]
            records = configuration.activeAgentIDs.map { agentID in
                let profile = configuration.profile(id: agentID)!
                return AgentQueueAgentPreparationRecord(
                    agentID: agentID,
                    surfaceID: agentID == AgentQueueAgentID.planner
                        ? plannerID
                        : workerID,
                    appliedProfileFingerprint: AgentQueueProfileFingerprint.make(profile),
                    appliedRoleSkillFingerprint: agentID == AgentQueueAgentID.planner
                        ? "planner-v1"
                        : "worker-v1",
                    phase: .ready,
                    errorMessage: nil
                )
            }
        }
        let state = AgentQueueState(
            queue: queue,
            tasks: [],
            workers: workers,
            bindings: bindings,
            events: [],
            preparation: AgentQueuePreparationState(
                configuration: configuration,
                phase: prepared ? .ready : .notPrepared,
                completedWorkerCount: prepared ? 1 : 0,
                errorMessage: nil,
                records: records,
                desiredRoleSkillFingerprints: [
                    AgentQueueRoleSkill.planner.rawValue: "planner-v1",
                    AgentQueueRoleSkill.worker.rawValue: "worker-v1",
                ]
            )
        )
        let persistence = ControllerNoopPersistence()
        coordinator = AgentQueueCoordinator(
            workspaceID: workspaceID,
            persistenceID: workspaceID,
            legacyWorkspaceID: nil,
            initialState: state,
            persistence: persistence,
            now: { now }
        )
        let adapter = ControllerPaneAdapter()
        preparer = ControllerPreparer(
            plannerSurfaceID: plannerSurfaceID,
            workerSurfaceID: workerSurfaceID
        )
        let effectExecutor = AgentQueueEffectExecutor(
            coordinator: coordinator,
            paneAdapter: adapter
        )
        controller = AgentQueueController(
            initialState: state,
            plannerSurfaceID: plannerSurfaceID,
            paneAdapter: adapter,
            coordinator: coordinator,
            effectExecutor: effectExecutor,
            roleSkillInstaller: ControllerRoleSkillInstaller(),
            workerPreparer: preparer,
            readinessTimeout: .zero,
            sleep: { _ in },
            skillSourceExists: { _ in true },
            now: { now }
        )
    }

    private static func binding(
        id: String,
        agentID: String,
        role: AgentQueueAgentRole,
        workspaceID: UUID,
        surfaceID: UUID,
        now: Date
    ) -> AgentQueueAgentBinding {
        AgentQueueAgentBinding(
            bindingID: id,
            agentID: agentID,
            role: role,
            workspaceID: workspaceID,
            paneID: surfaceID,
            surfaceID: surfaceID,
            readiness: .ready,
            preparedAt: now,
            readyDeadline: now.addingTimeInterval(30),
            readyAt: now,
            lastSeenAt: now,
            observedSessionID: nil
        )
    }
}

@MainActor
private final class ControllerPreparer: AgentQueueWorkerPreparing {
    let plannerSurfaceID: UUID
    let workerSurfaceID: UUID
    var onBootstrap: (([AgentQueueAgentBinding]) async throws -> Void)?
    private(set) var bootstrapBindingIDs: Set<String> = []
    private(set) var closeRequestCount = 0

    init(plannerSurfaceID: UUID, workerSurfaceID: UUID) {
        self.plannerSurfaceID = plannerSurfaceID
        self.workerSurfaceID = workerSurfaceID
    }

    func prepareTopology(
        configuration _: AgentQueuePreparationConfiguration,
        plannerSurfaceID _: UUID,
        existingWorkerSlots _: [AgentQueueWorkerSlot],
        activeWorkerAgentIDs _: Set<String>
    ) async throws -> AgentQueuePreparedTopology {
        AgentQueuePreparedTopology(
            plannerSurfaceID: plannerSurfaceID,
            workerSlots: [AgentQueueWorkerSlot(agentID: "worker-1", surfaceID: workerSurfaceID)],
            workingDirectory: "/tmp/repo"
        )
    }

    func bootstrap(
        topology _: AgentQueuePreparedTopology,
        bindings: [AgentQueueAgentBinding],
        configuration _: AgentQueuePreparationConfiguration
    ) async -> [AgentQueueAgentPreparationFailure] {
        bootstrapBindingIDs = Set(bindings.map(\.bindingID))
        do {
            try await onBootstrap?(bindings)
            return []
        } catch {
            return bindings.map {
                AgentQueueAgentPreparationFailure(
                    agentID: $0.agentID,
                    surfaceID: $0.surfaceID,
                    message: error.localizedDescription
                )
            }
        }
    }
}

private struct ControllerRoleSkillInstaller: AgentQueueRoleSkillInstalling {
    func pendingChanges() async throws -> [AgentQueueRoleSkillChange] { [] }
    func apply(_: [AgentQueueRoleSkillChange]) async throws {}
    func fingerprint(for role: AgentQueueRoleSkill) async throws -> String {
        "\(role.rawValue)-v1"
    }
}

private final class ControllerPaneAdapter: AgentQueuePaneAdapting, Sendable {
    func submitText(_ text: String, to surfaceID: UUID) async throws -> AgentQueueSendResult {
        AgentQueueSendResult(surfaceID: surfaceID, queued: false)
    }

    func submitShellCommand(_ command: String, to surfaceID: UUID) async throws -> AgentQueueSendResult {
        AgentQueueSendResult(surfaceID: surfaceID, queued: false)
    }
}

private struct ControllerNoopPersistence: AgentQueuePersisting {
    func load(persistenceID _: UUID, legacyWorkspaceID _: UUID?) throws -> Data? { nil }
    func save(_: Data, persistenceID _: UUID) throws {}
    func removeLegacyState(workspaceID _: UUID) throws {}
}
