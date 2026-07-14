import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent Queue instruction builder")
struct AgentQueueInstructionBuilderTests {
    @Test
    func workerInstructionUsesNonDetectableReportTemplateWithoutRepeatingRole() {
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
        #expect(!text.contains("$cmux-agent-queue-worker"))
        #expect(!text.contains("$sample-domain-skill"))
        #expect(!text.contains("[AGENT_QUEUE_ROLE_START]"))
        #expect(text.contains("[AGENT_QUEUE_TASK]"))
        #expect(text.contains("task_id: T-20260709-0004"))
        #expect(text.contains("worker_surface_id: surface:33333333-3333-3333-3333-333333333333"))
        #expect(text.contains("report_target: current_pane"))
        #expect(text.contains("완료 보고 [task_id]:"))
        #expect(!text.contains("완료 보고 [T-20260709-0004]:"))
        #expect(text.contains("현재 대화"))
        #expect(!text.contains("planner_surface_id"))
        #expect(!text.localizedCaseInsensitiveContains("cmux send"))
        #expect(text.hasSuffix("\n"))
    }

    @Test
    func recoveryPromptForcesThreeAllowedStatusesWithoutRepeatingRole() {
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

        #expect(!text.contains("$cmux-agent-queue-worker"))
        #expect(!text.contains("$sample-domain-skill"))
        #expect(!text.contains("[AGENT_QUEUE_ROLE_START]"))
        #expect(text.contains("복구 요청 [T-20260709-0007]"))
        #expect(text.contains("- completed: 완료 보고 전문"))
        #expect(text.contains("- blocked: 막힌 이유"))
        #expect(text.contains("- running: 현재 진행 상황과 예상 남은 작업"))
        #expect(text.contains("현재 대화"))
        #expect(!text.localizedCaseInsensitiveContains("planner surface"))
        #expect(!text.localizedCaseInsensitiveContains("cmux send"))
        #expect(text.hasSuffix("\n"))
    }

    @Test
    func plannerInstructionDoesNotRepeatSkillsOrRole() {
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
        let instruction = "자동 복구 보고 [T-20260709-0008]: done"

        let text = AgentQueueInstructionBuilder.plannerInstruction(
            instruction,
            profile: profile
        )

        #expect(text == instruction)
        #expect(!text.contains("$cmux-agent-queue-planner"))
        #expect(!text.contains("$product-director"))
        #expect(!text.contains("[AGENT_QUEUE_ROLE_START]"))
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
