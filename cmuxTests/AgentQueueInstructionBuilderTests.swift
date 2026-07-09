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
        let planner = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let worker = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        let text = AgentQueueInstructionBuilder.workerInstruction(
            context: AgentQueueInstructionContext(
                task: task,
                plannerSurfaceID: planner,
                workerSurfaceID: worker
            )
        )

        XCTAssertTrue(text.contains("[AGENT_QUEUE_TASK]"))
        XCTAssertTrue(text.contains("task_id: T-20260709-0004"))
        XCTAssertTrue(text.contains("planner_surface_id: surface:22222222-2222-2222-2222-222222222222"))
        XCTAssertTrue(text.contains("worker_surface_id: surface:33333333-3333-3333-3333-333333333333"))
        XCTAssertTrue(text.contains("완료 보고 [T-20260709-0004]:"))
        XCTAssertTrue(text.contains("자기 pane에만 보고하지 마세요."))
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testRecoveryPromptForcesThreeAllowedStatuses() {
        let task = AgentTask.queueTestTask(id: "T-20260709-0007")
        let planner = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let text = AgentQueueInstructionBuilder.recoveryPrompt(task: task, plannerSurfaceID: planner)

        XCTAssertTrue(text.contains("복구 요청 [T-20260709-0007]"))
        XCTAssertTrue(text.contains("- completed: 완료 보고 전문"))
        XCTAssertTrue(text.contains("- blocked: 막힌 이유"))
        XCTAssertTrue(text.contains("- running: 현재 진행 상황과 예상 남은 작업"))
        XCTAssertTrue(text.contains("planner surface:22222222-2222-2222-2222-222222222222"))
    }

    func testCorrectionPromptDirectsReportToPlannerSurface() {
        let planner = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let text = AgentQueueInstructionBuilder.correctionPrompt(
            taskID: "T-20260709-0008",
            plannerSurfaceID: planner
        )

        XCTAssertTrue(text.contains("보고 위치 교정 [T-20260709-0008]"))
        XCTAssertTrue(text.contains("완료 보고는 자기 pane이 아니라 planner surface:22222222-2222-2222-2222-222222222222 로 전송해야 합니다."))
        XCTAssertTrue(text.contains("Enter로 제출하세요."))
        XCTAssertTrue(text.hasSuffix("\n"))
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
