import Foundation

extension CMUXCLI {
    static var agentQueueUsage: String {
        String(localized: "cli.agentQueue.usage", defaultValue: """
        Usage: cmux agent-queue <subcommand>

        Subcommands:
          enqueue --stdin
          report --task ID --report ID --status completed|failed|blocked --binding ID [--stdin]
          agent ready --agent ID --role planner|worker --binding ID
          agent offline --agent ID --binding ID
          agent list
          agent remove --agent ID [--binding ID]
          agent reconcile
          task list
          pause
          resume
        """)
    }

    func validateAgentQueueCommandBeforeSocket(
        commandArgs: [String],
        environment: [String: String]
    ) throws {
        _ = try agentQueueInvocation(
            commandArgs: commandArgs,
            environment: environment,
            stdin: nil,
            validationOnly: true
        )
    }

    func runAgentQueueCommand(
        commandArgs: [String],
        client: SocketClient,
        environment: [String: String]
    ) throws {
        let stdin: Data?
        if commandArgs.contains("--stdin") {
            stdin = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            stdin = nil
        }
        let invocation = try agentQueueInvocation(
            commandArgs: commandArgs,
            environment: environment,
            stdin: stdin,
            validationOnly: false
        )

        do {
            let result = try client.sendV2(
                method: invocation.method,
                params: invocation.params
            )
            print(jsonString(result))
        } catch let error as CLIError {
            let code = error.rpcErrorCode ?? "transport_error"
            let message = error.rpcErrorMessage ?? error.message
            throw agentQueueStructuredError(
                code: code,
                message: message,
                exitCode: 1
            )
        } catch {
            throw agentQueueStructuredError(
                code: "transport_error",
                message: error.localizedDescription,
                exitCode: 1
            )
        }
    }

    func agentQueueTransportError(_ error: Error) -> CLIError {
        agentQueueStructuredError(
            code: "transport_error",
            message: String(describing: error),
            exitCode: 1
        )
    }

    private func agentQueueInvocation(
        commandArgs: [String],
        environment: [String: String],
        stdin: Data?,
        validationOnly: Bool
    ) throws -> AgentQueueCLIInvocation {
        guard let workspace = environment["CMUX_WORKSPACE_ID"].flatMap(UUID.init(uuidString:)),
              let surface = environment["CMUX_SURFACE_ID"].flatMap(UUID.init(uuidString:)) else {
            throw agentQueueStructuredError(
                code: "invalid_params",
                message: String(
                    localized: "cli.agentQueue.error.contextRequired",
                    defaultValue: "agent-queue requires CMUX_WORKSPACE_ID and CMUX_SURFACE_ID"
                ),
                exitCode: 2
            )
        }
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw agentQueueInvalidArgument(Self.agentQueueUsage)
        }

        var params: [String: Any] = [
            "workspace_id": workspace.uuidString,
            "surface_id": surface.uuidString,
        ]
        let arguments = Array(commandArgs.dropFirst())

        switch subcommand {
        case "enqueue":
            let flags = try AgentQueueCLIFlags(
                arguments,
                valueOptions: [],
                booleanOptions: ["--stdin"],
                invalid: agentQueueInvalidArgument
            )
            guard flags.has("--stdin") else {
                throw agentQueueMissingOption("--stdin")
            }
            if validationOnly {
                params["submission"] = [:]
            } else {
                params["submission"] = try agentQueueJSONObject(from: stdin ?? Data())
            }
            return AgentQueueCLIInvocation(method: "agent_queue.task.enqueue", params: params)

        case "report":
            let flags = try AgentQueueCLIFlags(
                arguments,
                valueOptions: ["--task", "--report", "--status", "--binding"],
                booleanOptions: ["--stdin"],
                invalid: agentQueueInvalidArgument
            )
            params["task_id"] = try flags.required("--task", missing: agentQueueMissingOption)
            params["report_id"] = try flags.required("--report", missing: agentQueueMissingOption)
            let status = try flags.required("--status", missing: agentQueueMissingOption)
            guard ["completed", "failed", "blocked"].contains(status) else {
                throw agentQueueStructuredError(
                    code: "invalid_params",
                    message: String(
                        localized: "cli.agentQueue.error.invalidStatus",
                        defaultValue: "Status must be completed, failed, or blocked."
                    ),
                    exitCode: 2
                )
            }
            params["status"] = status
            params["binding_id"] = try flags.required("--binding", missing: agentQueueMissingOption)
            params["body"] = validationOnly || !flags.has("--stdin")
                ? ""
                : try agentQueueUTF8(stdin ?? Data())
            return AgentQueueCLIInvocation(method: "agent_queue.task.report", params: params)

        case "agent":
            return try agentQueueAgentInvocation(arguments, baseParams: params)

        case "task":
            guard arguments.map({ $0.lowercased() }) == ["list"] else {
                throw agentQueueInvalidArgument(arguments.joined(separator: " "))
            }
            return AgentQueueCLIInvocation(method: "agent_queue.task.list", params: params)

        case "pause", "resume":
            guard arguments.isEmpty else {
                throw agentQueueInvalidArgument(arguments.joined(separator: " "))
            }
            return AgentQueueCLIInvocation(method: "agent_queue.\(subcommand)", params: params)

        default:
            throw agentQueueInvalidArgument(subcommand)
        }
    }

    private func agentQueueAgentInvocation(
        _ arguments: [String],
        baseParams: [String: Any]
    ) throws -> AgentQueueCLIInvocation {
        guard let action = arguments.first?.lowercased() else {
            throw agentQueueInvalidArgument("agent")
        }
        let remaining = Array(arguments.dropFirst())
        var params = baseParams

        switch action {
        case "ready":
            let flags = try AgentQueueCLIFlags(
                remaining,
                valueOptions: ["--agent", "--role", "--binding"],
                booleanOptions: [],
                invalid: agentQueueInvalidArgument
            )
            params["agent_id"] = try flags.required("--agent", missing: agentQueueMissingOption)
            let role = try flags.required("--role", missing: agentQueueMissingOption)
            guard ["planner", "worker"].contains(role) else {
                throw agentQueueInvalidArgument(role)
            }
            params["role"] = role
            params["binding_id"] = try flags.required("--binding", missing: agentQueueMissingOption)
            return AgentQueueCLIInvocation(method: "agent_queue.agent.ready", params: params)

        case "offline":
            let flags = try AgentQueueCLIFlags(
                remaining,
                valueOptions: ["--agent", "--binding"],
                booleanOptions: [],
                invalid: agentQueueInvalidArgument
            )
            params["agent_id"] = try flags.required("--agent", missing: agentQueueMissingOption)
            params["binding_id"] = try flags.required("--binding", missing: agentQueueMissingOption)
            return AgentQueueCLIInvocation(method: "agent_queue.agent.offline", params: params)

        case "list", "reconcile":
            guard remaining.isEmpty else {
                throw agentQueueInvalidArgument(remaining.joined(separator: " "))
            }
            return AgentQueueCLIInvocation(method: "agent_queue.agent.\(action)", params: params)

        case "remove":
            let flags = try AgentQueueCLIFlags(
                remaining,
                valueOptions: ["--agent", "--binding"],
                booleanOptions: [],
                invalid: agentQueueInvalidArgument
            )
            params["agent_id"] = try flags.required("--agent", missing: agentQueueMissingOption)
            if let binding = flags.value("--binding") {
                params["binding_id"] = binding
            }
            return AgentQueueCLIInvocation(method: "agent_queue.agent.remove", params: params)

        default:
            throw agentQueueInvalidArgument(action)
        }
    }

    private func agentQueueJSONObject(from data: Data) throws -> [String: Any] {
        let text = try agentQueueUTF8(data)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw agentQueueInvalidJSON()
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw agentQueueInvalidJSON()
        }
        return object
    }

    private func agentQueueUTF8(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw agentQueueStructuredError(
                code: "invalid_params",
                message: String(
                    localized: "cli.agentQueue.error.invalidUTF8",
                    defaultValue: "Agent Queue stdin must be valid UTF-8."
                ),
                exitCode: 2
            )
        }
        return text
    }

    private func agentQueueInvalidJSON() -> CLIError {
        agentQueueStructuredError(
            code: "invalid_params",
            message: String(
                localized: "cli.agentQueue.error.invalidJSON",
                defaultValue: "Agent Queue enqueue stdin must be a nonempty JSON object."
            ),
            exitCode: 2
        )
    }

    private func agentQueueMissingOption(_ option: String) -> CLIError {
        agentQueueStructuredError(
            code: "invalid_params",
            message: String.localizedStringWithFormat(
                String(
                    localized: "cli.agentQueue.error.missingOption",
                    defaultValue: "Missing required option: %@"
                ),
                option
            ),
            exitCode: 2
        )
    }

    private func agentQueueInvalidArgument(_ value: String) -> CLIError {
        agentQueueStructuredError(
            code: "invalid_params",
            message: String.localizedStringWithFormat(
                String(
                    localized: "cli.agentQueue.error.unknownSubcommand",
                    defaultValue: "Unknown agent-queue subcommand or option: %@"
                ),
                value
            ),
            exitCode: 2
        )
    }

    private func agentQueueStructuredError(
        code: String,
        message: String,
        exitCode: Int32
    ) -> CLIError {
        CLIError(
            message: message,
            exitCode: exitCode,
            structuredPayload: [
                "ok": false,
                "error": [
                    "code": code,
                    "message": message,
                ],
            ]
        )
    }
}

private struct AgentQueueCLIInvocation {
    let method: String
    let params: [String: Any]
}

private struct AgentQueueCLIFlags {
    private var values: [String: String] = [:]
    private var booleans: Set<String> = []

    init(
        _ arguments: [String],
        valueOptions: Set<String>,
        booleanOptions: Set<String>,
        invalid: (String) -> CLIError
    ) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard !values.keys.contains(argument), !booleans.contains(argument) else {
                throw invalid(argument)
            }
            if booleanOptions.contains(argument) {
                booleans.insert(argument)
                index += 1
                continue
            }
            guard valueOptions.contains(argument),
                  index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else {
                throw invalid(argument)
            }
            values[argument] = arguments[index + 1]
            index += 2
        }
    }

    func has(_ option: String) -> Bool {
        booleans.contains(option)
    }

    func value(_ option: String) -> String? {
        values[option]
    }

    func required(
        _ option: String,
        missing: (String) -> CLIError
    ) throws -> String {
        guard let value = values[option], !value.isEmpty else {
            throw missing(option)
        }
        return value
    }
}
