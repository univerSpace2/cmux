import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentQueueInstructionBuilderTests: XCTestCase {
    func testWorkerInstructionContainsTaskMarkerAndReportFormat() {
        let now = Date(timeIntervalSince1970: 1_782_998_400)
        let task = AgentTask(
            id: "T-20260709-0004",
            queueID: "queue-1",
            title: "Inspect pane API",
            body: "Inspect pane API and summarize the safe send path.",
            status: .queued,
            executionMode: .sequential,
            assignedWorkerSurfaceID: nil,
            dispatchAttemptCount: 0,
            recoveryAttemptCount: 0,
            timeoutSeconds: 1_800,
            retryLimit: 3,
            createdAt: now,
            dispatchedAt: nil,
            completedAt: nil,
            lastError: nil
        )
        let worker = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let profile = AgentQueueAgentProfile(
            id: "worker-1",
            additionalSkills: [
                AgentQueueSkillSelection(
                    name: "sample-domain-skill",
                    sourcePath: "/tmp/sample-domain-skill/SKILL.md"
                ),
                AgentQueueSkillSelection(
                    name: "careful",
                    sourcePath: "/tmp/careful/SKILL.md"
                ),
            ],
            rolePrompt: "Inspect first, then implement the smallest safe change."
        )

        let text = AgentQueueInstructionBuilder.workerInstruction(
            context: AgentQueueInstructionContext(
                task: task,
                workerSurfaceID: worker,
                profile: profile
            )
        )

        XCTAssertTrue(
            text.hasPrefix(
                "$cmux-agent-queue-worker $sample-domain-skill $careful\n\n" +
                    "[AGENT_QUEUE_ROLE_START]\n" +
                    "Inspect first, then implement the smallest safe change.\n"
            )
        )
        XCTAssertFalse(text.contains("[/AGENT_QUEUE_ROLE]"))
        XCTAssertFalse(text.contains("[AGENT_QUEUE_ROLE_END]"))
        XCTAssertTrue(text.contains("[AGENT_QUEUE_TASK]"))
        XCTAssertTrue(text.contains("task_id: T-20260709-0004"))
        XCTAssertTrue(text.contains("worker_surface_id: surface:33333333-3333-3333-3333-333333333333"))
        XCTAssertTrue(text.contains("report_target: current_pane"))
        XCTAssertTrue(text.contains("완료 보고 [T-20260709-0004]:"))
        XCTAssertTrue(text.contains("현재 대화"))
        XCTAssertFalse(text.contains("planner_surface_id"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("cmux send"))
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testRecoveryPromptForcesThreeAllowedStatusesInCurrentPaneWithSkills() {
        let task = AgentTask.queueTestTask(id: "T-20260709-0007")
        let profile = AgentQueueAgentProfile(
            id: "worker-1",
            additionalSkills: [
                AgentQueueSkillSelection(
                    name: "sample-domain-skill",
                    sourcePath: "/tmp/sample-domain-skill/SKILL.md"
                ),
            ],
            rolePrompt: "Own recovery evidence."
        )

        let text = AgentQueueInstructionBuilder.recoveryPrompt(task: task, profile: profile)

        XCTAssertTrue(text.hasPrefix("$cmux-agent-queue-worker $sample-domain-skill\n\n"))
        XCTAssertTrue(text.contains("[AGENT_QUEUE_ROLE_START]\nOwn recovery evidence."))
        XCTAssertFalse(text.contains("[/AGENT_QUEUE_ROLE]"))
        XCTAssertFalse(text.contains("[AGENT_QUEUE_ROLE_END]"))
        XCTAssertTrue(text.contains("복구 요청 [T-20260709-0007]"))
        XCTAssertTrue(text.contains("- completed: 완료 보고 전문"))
        XCTAssertTrue(text.contains("- blocked: 막힌 이유"))
        XCTAssertTrue(text.contains("- running: 현재 진행 상황과 예상 남은 작업"))
        XCTAssertTrue(text.contains("현재 대화"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("planner surface"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("cmux send"))
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testPlannerInstructionUsesPlannerSkillsAndRole() {
        let profile = AgentQueueAgentProfile(
            id: "planner",
            additionalSkills: [
                AgentQueueSkillSelection(
                    name: "product-director",
                    sourcePath: "/tmp/product-director/SKILL.md"
                ),
            ],
            rolePrompt: "Review worker evidence before accepting completion."
        )

        let text = AgentQueueInstructionBuilder.plannerInstruction(
            "자동 복구 보고 [T-20260709-0008]: done",
            profile: profile
        )

        XCTAssertTrue(text.hasPrefix("$cmux-agent-queue-planner $product-director\n\n"))
        XCTAssertTrue(
            text.contains(
                "[AGENT_QUEUE_ROLE_START]\n" +
                    "Review worker evidence before accepting completion."
            )
        )
        XCTAssertFalse(text.contains("[/AGENT_QUEUE_ROLE]"))
        XCTAssertFalse(text.contains("[AGENT_QUEUE_ROLE_END]"))
        XCTAssertTrue(text.hasSuffix("자동 복구 보고 [T-20260709-0008]: done"))
    }

    func testPlannerRequestContainsGoalRequestIDAndResponseContract() {
        let requestID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let profile = AgentQueueAgentProfile(
            id: "planner",
            additionalSkills: [
                AgentQueueSkillSelection(
                    name: "product-director",
                    sourcePath: "/tmp/product-director/SKILL.md"
                ),
            ],
            rolePrompt: "Break goals into executable queue work."
        )

        let text = AgentQueueInstructionBuilder.plannerRequest(
            goal: "Implement search.\nCover errors.",
            requestID: requestID,
            profile: profile
        )

        XCTAssertTrue(text.hasPrefix("$cmux-agent-queue-planner $product-director\n\n"))
        XCTAssertTrue(text.contains("[AGENT_QUEUE_ROLE_START]"))
        XCTAssertTrue(text.contains("[AGENT_QUEUE_PLAN_REQUEST]"))
        XCTAssertTrue(text.contains("request_id: 11111111-2222-3333-4444-555555555555"))
        XCTAssertTrue(text.contains("Implement search.\nCover errors."))
        XCTAssertTrue(text.contains("[AGENT_QUEUE_TASKS]"))
        XCTAssertTrue(
            text.contains("\"request_id\":\"11111111-2222-3333-4444-555555555555\"")
        )
        XCTAssertFalse(text.contains("[/AGENT_QUEUE_ROLE]"))
    }
}

private extension AgentTask {
    static func queueTestTask(id: String) -> AgentTask {
        let now = Date(timeIntervalSince1970: 1_782_998_400)
        return AgentTask(
            id: id,
            queueID: "queue-1",
            title: "Title",
            body: "Body",
            status: .queued,
            executionMode: .sequential,
            assignedWorkerSurfaceID: nil,
            dispatchAttemptCount: 0,
            recoveryAttemptCount: 0,
            timeoutSeconds: 1_800,
            retryLimit: 3,
            createdAt: now,
            dispatchedAt: nil,
            completedAt: nil,
            lastError: nil
        )
    }
}
