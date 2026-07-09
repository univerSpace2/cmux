import Foundation

struct AgentQueueInstructionContext: Equatable, Sendable {
    var task: AgentTask
    var plannerSurfaceID: UUID
    var workerSurfaceID: UUID
}

enum AgentQueueInstructionBuilder {
    static func workerInstruction(context: AgentQueueInstructionContext) -> String {
        """
        작업지시: \(context.task.body)

        완료 후 반드시 아래 task_id를 포함해 planner pane으로 보고하세요.
        자기 pane에만 보고하지 마세요.
        보고를 전송한 뒤 반드시 Enter로 제출하세요.

        [AGENT_QUEUE_TASK]
        task_id: \(context.task.id)
        planner_surface_id: surface:\(context.plannerSurfaceID.uuidString.lowercased())
        worker_surface_id: surface:\(context.workerSurfaceID.uuidString.lowercased())
        report_target: planner
        report_required: true
        [/AGENT_QUEUE_TASK]

        완료 보고 형식:
        완료 보고 [\(context.task.id)]: <요약>. 변경/생성: <paths or none>. 검증: <evidence>. 미실행: <reason>. 주의: <follow-up>.

        """
    }

    static func recoveryPrompt(task: AgentTask, plannerSurfaceID: UUID) -> String {
        """
        복구 요청 [\(task.id)]:
        이 task의 보고가 planner pane에서 감지되지 않았습니다.
        현재 상태를 아래 중 하나로 즉시 보고하세요:
        - completed: 완료 보고 전문
        - blocked: 막힌 이유
        - running: 현재 진행 상황과 예상 남은 작업
        반드시 planner surface:\(plannerSurfaceID.uuidString.lowercased()) 로 전송하고 Enter 제출하세요.

        """
    }

    static func correctionPrompt(taskID: String, plannerSurfaceID: UUID) -> String {
        """
        보고 위치 교정 [\(taskID)]:
        완료 보고는 자기 pane이 아니라 planner surface:\(plannerSurfaceID.uuidString.lowercased()) 로 전송해야 합니다.
        다음 작업부터는 완료 보고를 전송한 뒤 Enter로 제출하세요.

        """
    }
}
