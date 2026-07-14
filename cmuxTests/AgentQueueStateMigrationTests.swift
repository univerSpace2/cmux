import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent Queue state migration")
struct AgentQueueStateMigrationTests {
    @Test(arguments: ["dispatching", "dispatched", "awaiting_report", "retrying"])
    func legacyInFlightTaskBecomesBlocked(_ status: String) throws {
        let state = try AgentQueueStateMigration().decode(
            AgentQueueMigrationFixture.v1(taskStatus: status)
        )
        let task = try #require(state.tasks.first)

        #expect(state.schemaVersion == AgentQueueState.currentSchemaVersion)
        #expect(task.status == .blocked)
        #expect(task.lastError == "Blocked during Agent Queue protocol migration; inspect before retrying.")
        #expect(state.queue.status == .paused)
        #expect(state.bindings.allSatisfy { $0.readiness == .notReady })
    }

    @Test(arguments: ["queued", "completed", "failed", "blocked", "cancelled"])
    func legacySafeTaskStatusIsPreserved(_ status: String) throws {
        let state = try AgentQueueStateMigration().decode(
            AgentQueueMigrationFixture.v1(taskStatus: status)
        )

        #expect(state.tasks.first?.status.rawValue == status)
    }

    @Test
    func migrationIsIdempotent() throws {
        let once = try AgentQueueStateMigration().decode(
            AgentQueueMigrationFixture.v1(taskStatus: "awaiting_report")
        )
        let encoded = try JSONEncoder.agentQueue.encode(once)
        let twice = try AgentQueueStateMigration().decode(encoded)

        #expect(twice == once)
    }
}

private enum AgentQueueMigrationFixture {
    static func v1(taskStatus: String) -> Data {
        let object: [String: Any] = [
            "queue": [
                "id": "queue-1",
                "workspaceID": "11111111-1111-1111-1111-111111111111",
                "plannerSurfaceID": "22222222-2222-2222-2222-222222222222",
                "status": "running",
                "createdAt": "2026-07-09T00:00:00Z",
                "updatedAt": "2026-07-09T00:00:00Z",
            ],
            "tasks": [[
                "id": "T-20260709-0001",
                "queueID": "queue-1",
                "title": "Inspect parser",
                "body": "Preserve \\ paths and \"quotes\".",
                "status": taskStatus,
                "executionMode": "sequential",
                "assignedWorkerSurfaceID": "33333333-3333-3333-3333-333333333333",
                "dispatchAttemptCount": 1,
                "recoveryAttemptCount": 0,
                "timeoutSeconds": 1_800,
                "retryLimit": 1,
                "createdAt": "2026-07-09T00:00:00Z",
                "dispatchedAt": "2026-07-09T00:01:00Z",
            ]],
            "workers": [[
                "id": "worker-1",
                "workspaceID": "11111111-1111-1111-1111-111111111111",
                "paneID": "44444444-4444-4444-4444-444444444444",
                "surfaceID": "33333333-3333-3333-3333-333333333333",
                "label": "Worker 1",
                "enabled": true,
                "status": "running",
                "currentTaskID": "T-20260709-0001",
            ]],
            "events": [],
            "preparation": [
                "configuration": [
                    "workerCount": 1,
                    "plannerProfile": [
                        "id": "planner",
                        "additionalSkills": [],
                        "rolePrompt": "",
                    ],
                    "workerProfiles": (1...4).map { index in
                        [
                            "id": "worker-\(index)",
                            "additionalSkills": [],
                            "rolePrompt": "",
                        ] as [String: Any]
                    },
                ],
                "phase": "ready",
                "completedWorkerCount": 1,
                "records": [
                    [
                        "agentID": "planner",
                        "surfaceID": "22222222-2222-2222-2222-222222222222",
                        "phase": "ready",
                    ],
                    [
                        "agentID": "worker-1",
                        "surfaceID": "33333333-3333-3333-3333-333333333333",
                        "phase": "ready",
                    ],
                ],
                "desiredRoleSkillFingerprints": [:],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
