import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent Queue topology reconciliation", .serialized)
struct AgentQueueTopologyReconcilerTests {
    @Test
    @MainActor
    func idleWorkerCloseRemovesCapacityWithoutPausing() async throws {
        let fixture = AgentQueueCoreFixture.make(taskCount: 0, workerCount: 1)
        let coordinator = try makeCoordinator(state: fixture.state)
        let worker = try #require(fixture.state.workers.first)
        let reconciler = makeReconciler(coordinator: coordinator, live: [])

        await reconciler.handleSurfaceClosed(event(
            workspaceID: fixture.state.queue.workspaceID,
            surfaceID: worker.surfaceID
        ))

        let state = await coordinator.snapshot()
        #expect(state.bindings.contains(where: { $0.agentID == worker.id }) == false)
        #expect(state.queue.status == .running)
    }

    @Test
    @MainActor
    func activeWorkerCloseBlocksTaskAndPauses() async throws {
        var fixture = AgentQueueCoreFixture.make(taskCount: 1, workerCount: 1)
        fixture.assign(taskIndex: 0, workerIndex: 0)
        let coordinator = try makeCoordinator(state: fixture.state)
        let worker = try #require(fixture.state.workers.first)
        let reconciler = makeReconciler(coordinator: coordinator, live: [])

        await reconciler.handleSurfaceClosed(event(
            workspaceID: fixture.state.queue.workspaceID,
            surfaceID: worker.surfaceID
        ))

        let state = await coordinator.snapshot()
        #expect(state.tasks.first?.status == .blocked)
        #expect(state.queue.status == .paused)
    }

    @Test
    @MainActor
    func plannerCloseClearsRegistrationAndPauses() async throws {
        let fixture = AgentQueueCoreFixture.make(taskCount: 0, workerCount: 1)
        let coordinator = try makeCoordinator(state: fixture.state)
        let reconciler = makeReconciler(coordinator: coordinator, live: [])

        await reconciler.handleSurfaceClosed(event(
            workspaceID: fixture.state.queue.workspaceID,
            surfaceID: fixture.state.queue.plannerSurfaceID
        ))

        let state = await coordinator.snapshot()
        let planner = try #require(state.bindings.first(where: { $0.role == .planner }))
        #expect(planner.readiness == .notReady)
        #expect(planner.surfaceID == nil)
        #expect(state.queue.status == .paused)
    }

    @Test
    @MainActor
    func staleSurfaceCloseCannotRemoveReplacementBinding() async throws {
        var fixture = AgentQueueCoreFixture.make(taskCount: 0, workerCount: 1)
        let oldSurfaceID = try #require(fixture.state.workers.first?.surfaceID)
        let replacementSurfaceID = UUID()
        fixture.state.workers[0].surfaceID = replacementSurfaceID
        fixture.state.bindings[1].surfaceID = replacementSurfaceID
        fixture.state.bindings[1].bindingID = "binding-worker-replacement"
        fixture.state.workers[0].bindingID = "binding-worker-replacement"
        let coordinator = try makeCoordinator(state: fixture.state)
        let reconciler = makeReconciler(coordinator: coordinator, live: [replacementSurfaceID])

        await reconciler.handleSurfaceClosed(event(
            workspaceID: fixture.state.queue.workspaceID,
            surfaceID: oldSurfaceID
        ))

        #expect(await coordinator.snapshot().bindings.contains(where: {
            $0.bindingID == "binding-worker-replacement"
        }))
    }

    @Test
    @MainActor
    func endedProcessOnlyRemovesCurrentObservedSession() async throws {
        var fixture = AgentQueueCoreFixture.make(taskCount: 0, workerCount: 1)
        fixture.state.bindings[1].observedSessionID = "session-current"
        let coordinator = try makeCoordinator(state: fixture.state)
        let reconciler = makeReconciler(coordinator: coordinator, live: [
            fixture.state.queue.plannerSurfaceID,
            fixture.state.workers[0].surfaceID,
        ])

        await reconciler.handleProcessLifecycle(endedRecord(
            sessionID: "session-old",
            workspaceID: fixture.state.queue.workspaceID,
            surfaceID: fixture.state.workers[0].surfaceID
        ))
        #expect(await coordinator.snapshot().bindings.count == 2)

        await reconciler.handleProcessLifecycle(endedRecord(
            sessionID: "session-current",
            workspaceID: fixture.state.queue.workspaceID,
            surfaceID: fixture.state.workers[0].surfaceID
        ))
        #expect(await coordinator.snapshot().bindings.count == 1)
    }

    @Test
    @MainActor
    func reconcileRepairsMissedCloseWithoutTerminalReads() async throws {
        let fixture = AgentQueueCoreFixture.make(taskCount: 0, workerCount: 1)
        let coordinator = try makeCoordinator(state: fixture.state)
        var inventoryReads = 0
        let reconciler = AgentQueueTopologyReconciler(
            workspaceID: fixture.state.queue.workspaceID,
            coordinator: coordinator,
            liveSurfaceIDs: {
                inventoryReads += 1
                return [fixture.state.queue.plannerSurfaceID]
            },
            endedBindingIDs: { [] }
        )

        await reconciler.reconcileNow(cause: "test")

        let state = await coordinator.snapshot()
        #expect(inventoryReads == 1)
        #expect(state.bindings.count == 1)
        #expect(state.bindings.first?.role == .planner)
    }

    @MainActor
    private func makeReconciler(
        coordinator: AgentQueueCoordinator,
        live: Set<UUID>
    ) -> AgentQueueTopologyReconciler {
        AgentQueueTopologyReconciler(
            workspaceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            coordinator: coordinator,
            liveSurfaceIDs: { live },
            endedBindingIDs: { [] }
        )
    }

    private func makeCoordinator(state: AgentQueueState) throws -> AgentQueueCoordinator {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-queue-reconcile-\(UUID().uuidString)",
            isDirectory: true
        )
        return AgentQueueCoordinator(
            workspaceID: state.queue.workspaceID,
            persistenceID: UUID(),
            legacyWorkspaceID: nil,
            initialState: state,
            persistence: AgentQueueFilePersistence(rootDirectory: root)
        )
    }

    private func event(workspaceID: UUID, surfaceID: UUID) -> CmuxSurfaceClosedEvent {
        CmuxSurfaceClosedEvent(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            paneID: nil,
            origin: "test"
        )
    }

    private func endedRecord(
        sessionID: String,
        workspaceID: UUID,
        surfaceID: UUID
    ) -> AgentChatSessionRecord {
        AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: .codex,
            workspaceID: workspaceID.uuidString,
            surfaceID: surfaceID.uuidString,
            workingDirectory: nil,
            transcriptPath: nil,
            state: .ended,
            endedAt: Date(),
            lastActivityAt: Date(),
            title: nil,
            pid: nil,
            hookStoreSessionID: nil
        )
    }
}
