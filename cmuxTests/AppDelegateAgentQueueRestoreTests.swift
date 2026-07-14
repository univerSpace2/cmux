import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent Queue session restore", .serialized)
struct AppDelegateAgentQueueRestoreTests {
    @Test
    @MainActor
    func stableIdentityRestoreRegistersCoordinatorWithoutChangingSelection() async throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.tabs.first)
        let selectedID = manager.selectedWorkspace?.id
        let focusedSurfaceID = workspace.focusedPanelId
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-queue-stable-restore-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            manager.tabs.forEach { $0.teardownAllPanels() }
        }
        let persistence = AgentQueueFilePersistence(rootDirectory: root)
        try persistence.save(
            JSONEncoder.agentQueue.encode(persistedState(workspace: workspace)),
            persistenceID: workspace.stableId
        )
        let registry = AgentQueueCoordinatorRegistry()
        let factory = AgentQueueControllerFactory(
            registry: registry,
            persistence: persistence
        )

        await factory.restorePersistedControllers([
            AgentQueueRestoreCandidate(
                workspace: workspace,
                tabManager: manager,
                persistenceID: workspace.stableId,
                legacyWorkspaceID: nil
            ),
        ])

        let coordinator = try #require(
            await registry.coordinator(workspaceID: workspace.id)
        )
        #expect(await coordinator.snapshot().queue.workspaceID == workspace.id)
        #expect(manager.selectedWorkspace?.id == selectedID)
        #expect(workspace.focusedPanelId == focusedSurfaceID)
    }

    @Test
    @MainActor
    func legacyFileMigratesOnlyWhenStableIdentityWasAdopted() async throws {
        let source = TabManager(autoWelcomeIfNeeded: false)
        let sourceWorkspace = try #require(source.tabs.first)
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        let savedWorkspace = try #require(snapshot.workspaces.first)
        let legacyID = try #require(savedWorkspace.workspaceId)
        let stableID = try #require(savedWorkspace.stableId)

        let restored = TabManager(autoWelcomeIfNeeded: false)
        restored.restoreSessionSnapshot(snapshot)
        let candidates = AppDelegate.agentQueueRestoreCandidates(
            snapshot: snapshot,
            tabManager: restored
        )
        let candidate = try #require(candidates.first)
        #expect(candidate.persistenceID == stableID)
        #expect(candidate.legacyWorkspaceID == legacyID)

        let duplicate = TabManager(autoWelcomeIfNeeded: false)
        duplicate.restoreSessionSnapshot(
            snapshot,
            excludingStableIdentities: [stableID]
        )
        let duplicateCandidate = try #require(
            AppDelegate.agentQueueRestoreCandidates(
                snapshot: snapshot,
                tabManager: duplicate
            ).first
        )
        #expect(duplicateCandidate.persistenceID != stableID)
        #expect(duplicateCandidate.legacyWorkspaceID == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-queue-legacy-restore-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            source.tabs.forEach { $0.teardownAllPanels() }
            restored.tabs.forEach { $0.teardownAllPanels() }
            duplicate.tabs.forEach { $0.teardownAllPanels() }
        }
        let persistence = AgentQueueFilePersistence(rootDirectory: root)
        try persistence.save(
            JSONEncoder.agentQueue.encode(persistedState(workspace: sourceWorkspace)),
            persistenceID: legacyID
        )
        let registry = AgentQueueCoordinatorRegistry()
        let factory = AgentQueueControllerFactory(
            registry: registry,
            persistence: persistence
        )
        await factory.restorePersistedControllers([candidate])

        let stableURL = root.appendingPathComponent("\(stableID.uuidString.lowercased()).json")
        let legacyURL = root.appendingPathComponent("\(legacyID.uuidString.lowercased()).json")
        #expect(FileManager.default.fileExists(atPath: stableURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(await registry.coordinator(workspaceID: candidate.workspace.id) != nil)
    }

    @MainActor
    private func persistedState(workspace: Workspace) -> AgentQueueState {
        let now = Date(timeIntervalSince1970: 1_784_006_400)
        return AgentQueueState(
            queue: AgentQueue(
                id: "queue-persisted",
                workspaceID: workspace.id,
                plannerSurfaceID: workspace.focusedPanelId ?? UUID(),
                status: .paused,
                createdAt: now,
                updatedAt: now
            ),
            tasks: [],
            workers: [],
            bindings: [],
            events: []
        )
    }
}
