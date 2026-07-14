import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("cmux agent-queue wire protocol", .serialized)
struct CMUXCLIAgentQueueRegressionTests {
    private let workspaceID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let surfaceID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    @Test
    func enqueuePreservesSpecialCharactersOnWire() async throws {
        let exactBody = """
        Quotes: "double" and 'single'
        Paths: C:\\Users\\agent\\repo and \\server\\share
        Escapes: literal \\n \\t \\u1234
        Tabs:	between
        Unicode: 작업 計画 🚀
        ```swift
        let value = "\\\"quoted\\\""
        ```
        """
        let submission: [String: Any] = [
            "submission_id": "sub-special-1",
            "tasks": [[
                "title": "Parser \\ \"quotes\" 작업",
                "body": exactBody,
                "execution_mode": "parallel",
                "timeout_seconds": 1_800,
                "retry_limit": 1,
            ]],
        ]
        let input = try JSONSerialization.data(withJSONObject: submission)
        let exchange = try runWithServer(
            arguments: ["agent-queue", "enqueue", "--stdin"],
            stdin: input
        )
        defer { exchange.server.stop() }

        #expect(exchange.process.status == 0)
        let request = try decodedRequest(await exchange.server.receivedLine())
        #expect(request.method == "agent_queue.task.enqueue")
        #expect(request.params["workspace_id"] as? String == workspaceID.uuidString)
        #expect(request.params["surface_id"] as? String == surfaceID.uuidString)
        let sentSubmission = try #require(request.params["submission"] as? [String: Any])
        let sentTasks = try #require(sentSubmission["tasks"] as? [[String: Any]])
        #expect(sentTasks.first?["title"] as? String == "Parser \\ \"quotes\" 작업")
        #expect(sentTasks.first?["body"] as? String == exactBody)
        #expect(try JSONSerialization.jsonObject(with: Data(exchange.process.stdout.utf8)) is [String: Any])
    }

    @Test
    func reportSendsPlainUTF8BodyAndBinding() async throws {
        let body = "done \\ \"quoted\" 작업\n두 번째 줄"
        let exchange = try runWithServer(
            arguments: [
                "agent-queue", "report",
                "--task", "T-20260714-0001",
                "--report", "report-special-1",
                "--status", "completed",
                "--binding", "binding-worker-1",
                "--stdin",
            ],
            stdin: Data(body.utf8)
        )
        defer { exchange.server.stop() }

        #expect(exchange.process.status == 0)
        let request = try decodedRequest(await exchange.server.receivedLine())
        #expect(request.method == "agent_queue.task.report")
        #expect(request.params["task_id"] as? String == "T-20260714-0001")
        #expect(request.params["report_id"] as? String == "report-special-1")
        #expect(request.params["status"] as? String == "completed")
        #expect(request.params["binding_id"] as? String == "binding-worker-1")
        #expect(request.params["body"] as? String == body)
    }

    @Test
    func readyMapsAgentRoleAndBinding() async throws {
        let exchange = try runWithServer(arguments: [
            "agent-queue", "agent", "ready",
            "--agent", "worker-1",
            "--role", "worker",
            "--binding", "binding-worker-1",
        ])
        defer { exchange.server.stop() }

        #expect(exchange.process.status == 0)
        let request = try decodedRequest(await exchange.server.receivedLine())
        #expect(request.method == "agent_queue.agent.ready")
        #expect(request.params["agent_id"] as? String == "worker-1")
        #expect(request.params["role"] as? String == "worker")
        #expect(request.params["binding_id"] as? String == "binding-worker-1")
    }

    @Test
    func missingWorkspaceOrSurfaceFailsBeforeSocketConnection() async throws {
        let socketPath = shortSocketPath()
        let server = try AgentQueueUnixSocketServer(path: socketPath, response: successResponse)
        defer { server.stop() }
        var environment = baseEnvironment(socketPath: socketPath)
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")

        let result = try runCLI(
            arguments: ["agent-queue", "task", "list"],
            environment: environment
        )

        #expect(result.status == 2)
        #expect(await server.receivedLine() == nil)
        let error = try decodedError(result.stderr)
        #expect(error.code == "invalid_params")
    }

    @Test
    func serverErrorUsesNonzeroExitAndJSONStderr() async throws {
        let response = """
        {"id":"test","ok":false,"error":{"code":"conflict","message":"duplicate submission"}}
        """
        let exchange = try runWithServer(
            arguments: ["agent-queue", "pause"],
            response: response
        )
        defer { exchange.server.stop() }

        #expect(exchange.process.status == 1)
        let error = try decodedError(exchange.process.stderr)
        #expect(error.code == "conflict")
        #expect(error.message == "duplicate submission")
    }

    @Test
    func helpListsEveryAgentQueueSubcommand() throws {
        let result = try runCLI(
            arguments: ["agent-queue", "--help"],
            environment: baseEnvironment(socketPath: shortSocketPath())
        )

        #expect(result.status == 0)
        for fragment in [
            "enqueue --stdin",
            "report --task",
            "agent ready",
            "agent offline",
            "agent list",
            "agent remove",
            "agent reconcile",
            "task list",
            "pause",
            "resume",
        ] {
            #expect(result.stdout.contains(fragment))
        }
    }

    private var successResponse: String {
        "{\"id\":\"test\",\"ok\":true,\"result\":{\"revision\":1}}"
    }

    private func runWithServer(
        arguments: [String],
        stdin: Data = Data(),
        response: String? = nil
    ) throws -> (process: AgentQueueCLIProcessResult, server: AgentQueueUnixSocketServer) {
        let socketPath = shortSocketPath()
        let server = try AgentQueueUnixSocketServer(
            path: socketPath,
            response: response ?? successResponse
        )
        let process = try runCLI(
            arguments: arguments,
            stdin: stdin,
            environment: baseEnvironment(socketPath: socketPath)
        )
        return (process, server)
    }

    private func baseEnvironment(socketPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = workspaceID.uuidString
        environment["CMUX_SURFACE_ID"] = surfaceID.uuidString
        return environment
    }

    private func runCLI(
        arguments: [String],
        stdin: Data = Data(),
        environment: [String: String]
    ) throws -> AgentQueueCLIProcessResult {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        ))
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(stdin)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return AgentQueueCLIProcessResult(
            status: process.terminationStatus,
            stdout: String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            stderr: String(
                data: error.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }

    private func decodedRequest(
        _ line: String?
    ) throws -> (method: String, params: [String: Any]) {
        let line = try #require(line)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        return (
            try #require(object["method"] as? String),
            try #require(object["params"] as? [String: Any])
        )
    }

    private func decodedError(_ stderr: String) throws -> (code: String, message: String) {
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(stderr.utf8)) as? [String: Any]
        )
        let error = try #require(object["error"] as? [String: Any])
        return (
            try #require(error["code"] as? String),
            try #require(error["message"] as? String)
        )
    }

    private func shortSocketPath() -> String {
        "/tmp/cmx-aq-\(UUID().uuidString.prefix(8)).sock"
    }
}

private struct AgentQueueCLIProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private struct AgentQueueUnixSocketServer: Sendable {
    private let path: String
    private let listenerFD: Int32
    private let recorder: AgentQueueSocketRequestRecorder

    init(path: String, response: String) throws {
        self.path = path
        let recorder = AgentQueueSocketRequestRecorder()
        self.recorder = recorder
        unlink(path)
        let listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else { throw Self.posixError("socket") }
        self.listenerFD = listenerFD

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else { throw Self.posixError("path") }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                strncpy(
                    UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self),
                    source,
                    maxLength - 1
                )
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(listenerFD, 1) == 0 else {
            let error = Self.posixError("bind/listen")
            close(listenerFD)
            throw error
        }
        Task.detached(priority: .userInitiated) {
            await Self.serve(
                listenerFD: listenerFD,
                response: response,
                recorder: recorder
            )
        }
    }

    func receivedLine() async -> String? {
        await recorder.value()
    }

    func stop() {
        close(listenerFD)
        unlink(path)
    }

    private static func serve(
        listenerFD: Int32,
        response: String,
        recorder: AgentQueueSocketRequestRecorder
    ) async {
        let clientFD = accept(listenerFD, nil, nil)
        guard clientFD >= 0 else { return }
        defer { close(clientFD) }
        var data = Data()
        while true {
            var byte: UInt8 = 0
            guard read(clientFD, &byte, 1) == 1 else { return }
            if byte == 0x0A { break }
            data.append(byte)
        }
        await recorder.record(String(data: data, encoding: .utf8))
        let payload = response + "\n"
        payload.withCString { _ = write(clientFD, $0, strlen($0)) }
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"]
        )
    }
}

private actor AgentQueueSocketRequestRecorder {
    private var request: String?

    func record(_ request: String?) {
        self.request = request
    }

    func value() -> String? {
        request
    }
}
