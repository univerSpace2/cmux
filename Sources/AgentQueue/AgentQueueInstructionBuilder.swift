import Foundation

struct AgentQueueInstructionContext: Equatable, Sendable {
    var task: AgentTask
    var plannerSurfaceID: UUID
    var workerSurfaceID: UUID
}

enum AgentQueueInstructionBuilder {
    static func workerInstruction(context: AgentQueueInstructionContext) -> String {
        String(
            format: String(
                localized: "agentQueue.instruction.worker",
                defaultValue: "작업지시: %@\n\n완료 후 반드시 아래 task_id를 포함해 planner pane으로 보고하세요.\n자기 pane에만 보고하지 마세요.\n보고를 전송한 뒤 반드시 Enter로 제출하세요.\n\n[AGENT_QUEUE_TASK]\ntask_id: %@\nplanner_surface_id: surface:%@\nworker_surface_id: surface:%@\nreport_target: planner\nreport_required: true\n[/AGENT_QUEUE_TASK]\n\n완료 보고 형식:\n완료 보고 [%@]: <요약>. 변경/생성: <paths or none>. 검증: <evidence>. 미실행: <reason>. 주의: <follow-up>.\n"
            ),
            context.task.body,
            context.task.id,
            context.plannerSurfaceID.uuidString.lowercased(),
            context.workerSurfaceID.uuidString.lowercased(),
            context.task.id
        )
    }

    static func recoveryPrompt(task: AgentTask, plannerSurfaceID: UUID) -> String {
        String(
            format: String(
                localized: "agentQueue.instruction.recovery",
                defaultValue: "복구 요청 [%@]:\n이 task의 보고가 planner pane에서 감지되지 않았습니다.\n현재 상태를 아래 중 하나로 즉시 보고하세요:\n- completed: 완료 보고 전문\n- blocked: 막힌 이유\n- running: 현재 진행 상황과 예상 남은 작업\n반드시 planner surface:%@ 로 전송하고 Enter 제출하세요.\n"
            ),
            task.id,
            plannerSurfaceID.uuidString.lowercased()
        )
    }

    static func correctionPrompt(taskID: String, plannerSurfaceID: UUID) -> String {
        String(
            format: String(
                localized: "agentQueue.instruction.correction",
                defaultValue: "보고 위치 교정 [%@]:\n완료 보고는 자기 pane이 아니라 planner surface:%@ 로 전송해야 합니다.\n다음 작업부터는 완료 보고를 전송한 뒤 Enter로 제출하세요.\n"
            ),
            taskID,
            plannerSurfaceID.uuidString.lowercased()
        )
    }
}
