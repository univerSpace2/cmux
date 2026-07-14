import CmuxControlSocket
import Foundation

struct AgentQueueControlCallAdapter: Sendable {
    static func handle(
        _ call: ControlAgentQueueCall,
        coordinator: AgentQueueCoordinator
    ) async -> ControlCallResult {
        do {
            let caller = AgentQueueCallerContext(
                workspaceID: call.workspaceID,
                surfaceID: call.surfaceID
            )
            let snapshot = await coordinator.snapshot()
            guard snapshot.queue.workspaceID == call.workspaceID,
                  snapshot.bindings.contains(where: {
                      $0.workspaceID == call.workspaceID
                          && $0.surfaceID == call.surfaceID
                          && $0.readiness != .notReady
                  }) else {
                throw AgentQueueCoordinatorError.unauthorized("caller_surface")
            }

            switch call.method {
            case "agent_queue.agent.ready":
                guard let agentID = string(call.params, "agent_id"),
                      let roleRaw = string(call.params, "role"),
                      let role = AgentQueueAgentRole(rawValue: roleRaw),
                      let bindingID = string(call.params, "binding_id") else {
                    throw AgentQueueCoordinatorError.invalidRequest("ready")
                }
                return .ok(try jsonValue(await coordinator.markReady(
                    agentID: agentID,
                    role: role,
                    bindingID: bindingID,
                    caller: caller
                )))

            case "agent_queue.agent.offline":
                guard let agentID = string(call.params, "agent_id"),
                      let bindingID = string(call.params, "binding_id") else {
                    throw AgentQueueCoordinatorError.invalidRequest("offline")
                }
                try await coordinator.markOffline(
                    agentID: agentID,
                    bindingID: bindingID,
                    caller: caller,
                    cause: "agent reported offline"
                )
                return try await revisionResult(coordinator)

            case "agent_queue.agent.list":
                let current = await coordinator.snapshot()
                return .ok(try jsonValue(AgentListResponse(
                    bindings: current.bindings,
                    workers: current.workers,
                    revision: current.revision
                )))

            case "agent_queue.agent.remove":
                guard let agentID = string(call.params, "agent_id") else {
                    throw AgentQueueCoordinatorError.invalidRequest("agent_id")
                }
                try await coordinator.removeAgent(
                    agentID: agentID,
                    expectedBindingID: optionalString(call.params, "binding_id"),
                    cause: "manual registration removal"
                )
                return try await revisionResult(coordinator)

            case "agent_queue.agent.reconcile":
                let current = await coordinator.snapshot()
                try await coordinator.reconcile(
                    liveSurfaceIDs: Set(current.bindings.compactMap(\.surfaceID)),
                    endedBindingIDs: [],
                    cause: "manual reconciliation"
                )
                return try await revisionResult(coordinator)

            case "agent_queue.task.enqueue":
                guard let submission = call.params["submission"] else {
                    throw AgentQueueCoordinatorError.invalidRequest("submission")
                }
                let request = try decode(AgentQueueEnqueueRequest.self, from: submission)
                return .ok(try jsonValue(await coordinator.enqueue(request, caller: caller)))

            case "agent_queue.task.report":
                let request = try decode(
                    AgentQueueReportRequest.self,
                    from: .object(call.params)
                )
                return .ok(try jsonValue(await coordinator.report(request, caller: caller)))

            case "agent_queue.task.list":
                let current = await coordinator.snapshot()
                return .ok(try jsonValue(TaskListResponse(
                    tasks: current.tasks,
                    submissions: current.submissions,
                    reports: current.reports,
                    revision: current.revision
                )))

            case "agent_queue.pause":
                try await coordinator.pause(cause: "manual")
                return try await revisionResult(coordinator)

            case "agent_queue.resume":
                try await coordinator.resume()
                return try await revisionResult(coordinator)

            default:
                return .err(
                    code: "method_not_found",
                    message: "Unknown Agent Queue method",
                    data: nil
                )
            }
        } catch let error as AgentQueueCoordinatorError {
            return coordinatorError(error)
        } catch is DecodingError {
            return .err(
                code: "invalid_params",
                message: "Invalid Agent Queue payload",
                data: nil
            )
        } catch {
            return .err(
                code: "agent_queue_error",
                message: error.localizedDescription,
                data: nil
            )
        }
    }

    private static func revisionResult(
        _ coordinator: AgentQueueCoordinator
    ) async throws -> ControlCallResult {
        let current = await coordinator.snapshot()
        return .ok(try jsonValue(RevisionResponse(revision: current.revision)))
    }

    private static func coordinatorError(
        _ error: AgentQueueCoordinatorError
    ) -> ControlCallResult {
        switch error {
        case .conflict(let field):
            return .err(code: "conflict", message: "Conflicting \(field)", data: nil)
        case .invalidRequest(let field):
            return .err(code: "invalid_params", message: "Invalid \(field)", data: nil)
        case .unauthorized(let reason):
            return .err(code: "unauthorized", message: "Unauthorized: \(reason)", data: nil)
        case .notFound(let resource):
            return .err(code: "not_found", message: "Missing \(resource)", data: nil)
        case .staleBinding(let bindingID):
            return .err(
                code: "stale_binding",
                message: "Stale binding: \(bindingID)",
                data: nil
            )
        }
    }

    private static func string(
        _ params: [String: JSONValue],
        _ key: String
    ) -> String? {
        guard case .string(let value)? = params[key] else { return nil }
        return value
    }

    private static func optionalString(
        _ params: [String: JSONValue],
        _ key: String
    ) -> String? {
        guard let value = params[key] else { return nil }
        guard case .string(let string) = value else { return nil }
        return string
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from value: JSONValue
    ) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value.foundationObject)
        return try JSONDecoder.agentQueue.decode(type, from: data)
    }

    private static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder.agentQueue.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let result = JSONValue(foundationObject: object) else {
            throw AgentQueueCoordinatorError.invalidRequest("response")
        }
        return result
    }
}

private struct AgentListResponse: Encodable {
    var bindings: [AgentQueueAgentBinding]
    var workers: [AgentWorker]
    var revision: UInt64
}

private struct TaskListResponse: Encodable {
    var tasks: [AgentTask]
    var submissions: [AgentQueueSubmission]
    var reports: [AgentQueueTaskReport]
    var revision: UInt64
}

private struct RevisionResponse: Encodable {
    var revision: UInt64
}
