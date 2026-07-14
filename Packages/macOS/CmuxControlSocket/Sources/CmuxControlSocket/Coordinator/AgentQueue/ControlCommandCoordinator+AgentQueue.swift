internal import Foundation

private let controlAgentQueueMethods: Set<String> = [
    "agent_queue.agent.ready",
    "agent_queue.agent.offline",
    "agent_queue.agent.list",
    "agent_queue.agent.remove",
    "agent_queue.agent.reconcile",
    "agent_queue.task.enqueue",
    "agent_queue.task.report",
    "agent_queue.task.list",
    "agent_queue.pause",
    "agent_queue.resume",
]

extension ControlCommandCoordinator {
    /// Parses and validates an Agent Queue request on the socket-worker lane.
    ///
    /// This method never resolves focused UI state. Every request must carry
    /// concrete workspace and surface UUIDs before the app seam is invoked.
    ///
    /// - Parameters:
    ///   - request: Decoded JSON-RPC request.
    ///   - context: Async app-owned Agent Queue seam.
    /// - Returns: The command result, or `nil` for an unowned method.
    public nonisolated func handleAgentQueue(
        _ request: ControlRequest,
        context: any ControlAgentQueueContext
    ) async -> ControlCallResult? {
        guard controlAgentQueueMethods.contains(request.method) else { return nil }
        guard let workspaceID = agentQueueUUID(request.params, key: "workspace_id") else {
            return agentQueueInvalid("Missing or invalid workspace_id")
        }
        guard let surfaceID = agentQueueUUID(request.params, key: "surface_id") else {
            return agentQueueInvalid("Missing or invalid surface_id")
        }
        if let error = validateAgentQueuePayload(
            method: request.method,
            params: request.params
        ) {
            return error
        }

        var methodParams = request.params
        methodParams.removeValue(forKey: "workspace_id")
        methodParams.removeValue(forKey: "surface_id")
        return await context.controlAgentQueue(
            ControlAgentQueueCall(
                method: request.method,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                params: methodParams
            )
        )
    }

    private nonisolated func validateAgentQueuePayload(
        method: String,
        params: [String: JSONValue]
    ) -> ControlCallResult? {
        switch method {
        case "agent_queue.agent.ready":
            guard agentQueueNonemptyString(params, key: "agent_id"),
                  agentQueueString(params, key: "role", allowed: ["planner", "worker"]),
                  agentQueueNonemptyString(params, key: "binding_id") else {
                return agentQueueInvalid("Invalid Agent Queue ready payload")
            }
        case "agent_queue.agent.offline":
            guard agentQueueNonemptyString(params, key: "agent_id"),
                  agentQueueNonemptyString(params, key: "binding_id") else {
                return agentQueueInvalid("Invalid Agent Queue offline payload")
            }
        case "agent_queue.agent.remove":
            guard agentQueueNonemptyString(params, key: "agent_id"),
                  agentQueueOptionalNonemptyString(params, key: "binding_id") else {
                return agentQueueInvalid("Invalid Agent Queue remove payload")
            }
        case "agent_queue.task.enqueue":
            guard validateAgentQueueSubmission(params["submission"]) else {
                return agentQueueInvalid("Invalid Agent Queue submission payload")
            }
        case "agent_queue.task.report":
            guard agentQueueNonemptyString(params, key: "task_id"),
                  agentQueueNonemptyString(params, key: "report_id"),
                  agentQueueString(params, key: "status", allowed: ["completed", "failed", "blocked"]),
                  agentQueueNonemptyString(params, key: "binding_id"),
                  agentQueueString(params, key: "body") else {
                return agentQueueInvalid("Invalid Agent Queue report payload")
            }
        case "agent_queue.agent.list",
             "agent_queue.agent.reconcile",
             "agent_queue.task.list",
             "agent_queue.pause",
             "agent_queue.resume":
            break
        default:
            return agentQueueInvalid("Unsupported Agent Queue method")
        }
        return nil
    }

    private nonisolated func validateAgentQueueSubmission(_ value: JSONValue?) -> Bool {
        guard case .object(let submission)? = value,
              agentQueueNonemptyString(submission, key: "submission_id"),
              case .array(let tasks)? = submission["tasks"],
              !tasks.isEmpty else {
            return false
        }
        return tasks.allSatisfy { value in
            guard case .object(let task) = value,
                  agentQueueNonemptyString(task, key: "title"),
                  agentQueueNonemptyString(task, key: "body"),
                  agentQueueString(task, key: "execution_mode", allowed: ["parallel", "sequential"]),
                  agentQueuePositiveNumber(task["timeout_seconds"]),
                  agentQueueNonnegativeInteger(task["retry_limit"]) else {
                return false
            }
            return true
        }
    }

    private nonisolated func agentQueueUUID(
        _ params: [String: JSONValue],
        key: String
    ) -> UUID? {
        guard case .string(let value)? = params[key] else { return nil }
        return UUID(uuidString: value)
    }

    private nonisolated func agentQueueNonemptyString(
        _ params: [String: JSONValue],
        key: String
    ) -> Bool {
        guard case .string(let value)? = params[key] else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private nonisolated func agentQueueOptionalNonemptyString(
        _ params: [String: JSONValue],
        key: String
    ) -> Bool {
        guard params[key] != nil else { return true }
        return agentQueueNonemptyString(params, key: key)
    }

    private nonisolated func agentQueueString(
        _ params: [String: JSONValue],
        key: String
    ) -> Bool {
        guard case .string? = params[key] else { return false }
        return true
    }

    private nonisolated func agentQueueString(
        _ params: [String: JSONValue],
        key: String,
        allowed: Set<String>
    ) -> Bool {
        guard case .string(let value)? = params[key] else { return false }
        return allowed.contains(value)
    }

    private nonisolated func agentQueuePositiveNumber(_ value: JSONValue?) -> Bool {
        switch value {
        case .int(let number): return number > 0
        case .double(let number): return number.isFinite && number > 0
        default: return false
        }
    }

    private nonisolated func agentQueueNonnegativeInteger(_ value: JSONValue?) -> Bool {
        guard case .int(let number)? = value else { return false }
        return number >= 0
    }

    private nonisolated func agentQueueInvalid(_ message: String) -> ControlCallResult {
        .err(code: "invalid_params", message: message, data: nil)
    }
}
