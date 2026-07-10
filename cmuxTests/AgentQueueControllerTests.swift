import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class AgentQueueControllerTests: XCTestCase {
    func testStartDispatchesInstructionAndEnterToWorker() async throws {
        let fixture = AgentQueueControllerFixture()
        let controller = fixture.controller

        controller.createTasks(from: "Inspect repo")
        await controller.start()

        XCTAssertEqual(fixture.adapter.sentTexts.count, 1)
        XCTAssertTrue(fixture.adapter.sentTexts[0].text.contains("task_id: T-20260709-0001"))
        XCTAssertEqual(fixture.adapter.enterSurfaces, [fixture.workerSurfaceID])
        XCTAssertEqual(controller.state.tasks.first?.status, .awaitingReport)
    }

    func testWrongPaneReportIsForwardedToPlanner() async throws {
        var plannerProfile = AgentQueueAgentProfile.planner
        plannerProfile = plannerProfile.addingSkill(
            AgentQueueSkillSelection(
                name: "product-director",
                sourcePath: "/tmp/product-director/SKILL.md"
            )
        )
        plannerProfile.rolePrompt = "Review worker evidence."
        let configuration = try AgentQueuePreparationConfiguration.defaultConfiguration
            .replacingProfile(plannerProfile)
        let fixture = AgentQueueControllerFixture(configuration: configuration)
        let controller = fixture.controller

        controller.createTasks(from: "Inspect repo")
        await controller.start()
        fixture.adapter.textBySurface[fixture.workerSurfaceID] = "완료 보고 [T-20260709-0001]: done in worker pane"

        await controller.pollReportsOnce(now: fixture.now.addingTimeInterval(60))

        XCTAssertTrue(fixture.adapter.sentTexts.contains { item in
            item.surfaceID == fixture.plannerSurfaceID &&
                item.text.hasPrefix("$cmux-agent-queue-planner $product-director\n\n") &&
                item.text.contains("[AGENT_QUEUE_ROLE]\nReview worker evidence.\n[/AGENT_QUEUE_ROLE]") &&
                item.text.contains("자동 복구 보고 [T-20260709-0001]")
        })
        XCTAssertEqual(controller.state.tasks.first?.status, .completed)
    }

    func testDuplicateWorkerReportIsForwardedAndLoggedOnce() async {
        let fixture = AgentQueueControllerFixture()
        let controller = fixture.controller

        controller.createTasks(from: "Inspect repo")
        await controller.start()
        fixture.adapter.textBySurface[fixture.workerSurfaceID] =
            "완료 보고 [T-20260709-0001]: done in worker pane"

        await controller.pollReportsOnce(now: fixture.now.addingTimeInterval(60))
        await controller.pollReportsOnce(now: fixture.now.addingTimeInterval(61))

        XCTAssertEqual(
            fixture.adapter.sentTexts.filter { $0.surfaceID == fixture.plannerSurfaceID }.count,
            1
        )
        XCTAssertEqual(
            controller.state.events.filter { $0.type == .wrongPaneReportDetected }.count,
            1
        )
        XCTAssertEqual(controller.state.tasks.first?.status, .completed)
    }

    func testMonitoringPollsWithoutSidebarCallbacks() async {
        let fixture = AgentQueueControllerFixture(pollInterval: .milliseconds(10))
        let controller = fixture.controller

        controller.createTasks(from: "Inspect repo")
        await controller.start()
        fixture.adapter.textBySurface[fixture.workerSurfaceID] =
            "완료 보고 [T-20260709-0001]: done in worker pane"

        controller.startMonitoring()
        for _ in 0..<50 {
            if controller.state.tasks.first?.status == .completed { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        controller.stopMonitoring()

        XCTAssertEqual(controller.state.tasks.first?.status, .completed)
        XCTAssertGreaterThan(fixture.adapter.readCount, 0)
    }

    func testMalformedAndUnknownReportsAreLoggedAsIgnored() async {
        let fixture = AgentQueueControllerFixture()
        let controller = fixture.controller

        controller.createTasks(from: "Inspect repo")
        await controller.start()
        fixture.adapter.textBySurface[fixture.workerSurfaceID] = """
        완료 보고: done without id
        완료 보고 [T-20260709-9999]: unknown task
        """

        await controller.pollReportsOnce(now: fixture.now.addingTimeInterval(60))

        let ignoredEvents = controller.state.events.filter { $0.type == .ignoredReport }
        XCTAssertEqual(ignoredEvents.count, 2)
        XCTAssertEqual(Set(ignoredEvents.compactMap(\.evidence?.command)), ["missing_task_id", "unknown_task_id"])
        XCTAssertEqual(controller.state.tasks.first?.status, .awaitingReport)
    }

    func testEnterFailureDoesNotMarkTaskAwaitingReport() async {
        let fixture = AgentQueueControllerFixture()
        fixture.adapter.enterError = AgentQueuePaneAdapterError.surfaceUnavailable(fixture.workerSurfaceID)

        fixture.controller.createTasks(from: "Inspect repo")
        await fixture.controller.start()

        XCTAssertEqual(fixture.adapter.sentTexts.count, 1)
        XCTAssertEqual(fixture.adapter.enterSurfaces, [fixture.workerSurfaceID])
        XCTAssertEqual(fixture.controller.state.tasks.first?.status, .blocked)
        XCTAssertEqual(fixture.controller.state.queue.status, .paused)
        XCTAssertNotEqual(fixture.controller.state.tasks.first?.status, .awaitingReport)
    }

    func testStartDoesNothingUntilPreparationIsReady() async {
        let fixture = AgentQueueControllerFixture(prepared: false)

        fixture.controller.createTasks(from: "Inspect repo")
        await fixture.controller.start()

        XCTAssertFalse(fixture.controller.canStart)
        XCTAssertTrue(fixture.adapter.sentTexts.isEmpty)
        XCTAssertEqual(fixture.controller.state.tasks.first?.status, .queued)
        XCTAssertEqual(fixture.controller.state.queue.status, .paused)
    }

    func testPreparationWaitsForSkillConfirmationThenRegistersReturnedWorkers() async throws {
        let firstWorker = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let secondWorker = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let installer = FakeAgentQueueRoleSkillInstaller(
            pending: [
                AgentQueueRoleSkillChange(
                    role: .planner,
                    sourceURL: URL(fileURLWithPath: "/tmp/source/planner/SKILL.md"),
                    destinationURL: URL(fileURLWithPath: "/tmp/destination/planner/SKILL.md"),
                    kind: .install
                ),
            ]
        )
        let preparer = FakeAgentQueueWorkerPreparer(
            result: AgentQueuePreparedWorkspace(
                plannerSurfaceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                workerSurfaceIDs: [firstWorker, secondWorker],
                workingDirectory: "/tmp/project"
            )
        )
        let fixture = AgentQueueControllerFixture(
            prepared: false,
            includeWorker: false,
            installer: installer,
            preparer: preparer
        )
        fixture.controller.setPreparationConfiguration(
            try AgentQueuePreparationConfiguration(workerCount: 2, additionalSkill: nil)
        )

        await fixture.controller.prepareWorkers(allowSkillChanges: false)

        XCTAssertEqual(fixture.controller.state.preparation?.phase, .awaitingSkillConfirmation)
        XCTAssertEqual(fixture.controller.pendingRoleSkillChanges.map(\.role), [.planner])
        XCTAssertEqual(preparer.prepareCallCount, 0)
        XCTAssertTrue(fixture.controller.state.workers.isEmpty)

        await fixture.controller.prepareWorkers(allowSkillChanges: true)

        XCTAssertEqual(fixture.controller.state.preparation?.phase, .ready)
        XCTAssertEqual(fixture.controller.state.workers.map(\.surfaceID), [firstWorker, secondWorker])
        XCTAssertEqual(fixture.controller.state.workers.map(\.id), ["worker-1", "worker-2"])
        XCTAssertEqual(preparer.prepareCallCount, 1)
        let appliedRoles = await installer.appliedRoles()
        XCTAssertEqual(appliedRoles, [.planner])
    }

    func testDefaultPreparationConfigurationPersists() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentQueueStore(rootDirectory: directory)
        let fixture = AgentQueueControllerFixture(prepared: false, store: store)

        fixture.controller.setPreparationConfiguration(.defaultConfiguration)

        var loaded: AgentQueueState?
        for _ in 0..<50 {
            loaded = try await store.load(workspaceID: fixture.workspaceID)
            if loaded?.preparation?.configuration == .defaultConfiguration { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(loaded?.preparation?.configuration, .defaultConfiguration)
        XCTAssertEqual(loaded?.preparation?.phase, .notPrepared)
    }

    func testRestoreDropsUnavailableWorkersAndRequiresPreparationAgain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentQueueStore(rootDirectory: directory)
        let fixture = AgentQueueControllerFixture(
            prepared: false,
            includeWorker: false,
            store: store
        )
        let availableWorker = fixture.workerSurfaceID
        let unavailableWorker = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        fixture.adapter.unavailableSurfaceIDs.insert(unavailableWorker)
        var persisted = fixture.controller.state
        persisted.queue.status = .running
        persisted.preparation = AgentQueuePreparationState(
            configuration: try AgentQueuePreparationConfiguration(workerCount: 2, additionalSkill: nil),
            phase: .ready,
            completedWorkerCount: 2,
            errorMessage: nil
        )
        persisted.workers = [availableWorker, unavailableWorker].enumerated().map { index, surfaceID in
            AgentWorker(
                id: "worker-\(index + 1)",
                workspaceID: fixture.workspaceID,
                paneID: surfaceID,
                surfaceID: surfaceID,
                label: "Worker \(index + 1)",
                enabled: true,
                status: .idle,
                currentTaskID: nil,
                lastSeenAt: fixture.now
            )
        }
        try await store.save(persisted)

        await fixture.controller.restorePersistedState()

        XCTAssertEqual(fixture.controller.state.queue.status, .paused)
        XCTAssertEqual(fixture.controller.state.workers.map(\.surfaceID), [availableWorker])
        XCTAssertEqual(fixture.controller.state.preparation?.phase, .notPrepared)
        XCTAssertEqual(fixture.controller.state.preparation?.configuration.workerCount, 2)
    }

    func testRestoreDoesNotAdoptLegacyWorkersWithoutPreparationOwnership() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentQueueStore(rootDirectory: directory)
        let fixture = AgentQueueControllerFixture(
            prepared: false,
            includeWorker: false,
            store: store
        )
        var persisted = fixture.controller.state
        persisted.preparation = nil
        persisted.workers = [
            AgentWorker(
                id: "worker-1",
                workspaceID: fixture.workspaceID,
                paneID: fixture.workerSurfaceID,
                surfaceID: fixture.workerSurfaceID,
                label: "Legacy Worker",
                enabled: true,
                status: .idle,
                currentTaskID: nil,
                lastSeenAt: fixture.now
            ),
        ]
        try await store.save(persisted)

        await fixture.controller.restorePersistedState()

        XCTAssertNil(fixture.controller.state.preparation)
        XCTAssertTrue(fixture.controller.state.workers.isEmpty)
        XCTAssertFalse(fixture.controller.canStart)
    }

    func testDispatchIncludesPreparedWorkerSkillsAndRole() async throws {
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
            rolePrompt: "Own the assigned implementation."
        )
        let configuration = try AgentQueuePreparationConfiguration.defaultConfiguration
            .replacingProfile(profile)
        let fixture = AgentQueueControllerFixture(prepared: true, configuration: configuration)

        fixture.controller.createTasks(from: "Inspect repo")
        await fixture.controller.start()

        XCTAssertTrue(
            fixture.adapter.sentTexts[0].text.hasPrefix(
                "$cmux-agent-queue-worker $sample-domain-skill $careful\n\n" +
                    "[AGENT_QUEUE_ROLE]\n" +
                    "Own the assigned implementation.\n" +
                    "[/AGENT_QUEUE_ROLE]\n"
            )
        )
    }

    func testRepreparationPassesActiveWorkerAndPreservesTaskState() async {
        let preparer = FakeAgentQueueWorkerPreparer(
            result: AgentQueuePreparedWorkspace(
                plannerSurfaceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                workerSurfaceIDs: [UUID(uuidString: "33333333-3333-3333-3333-333333333333")!],
                workingDirectory: "/tmp/project"
            )
        )
        let fixture = AgentQueueControllerFixture(preparer: preparer)
        fixture.controller.createTasks(from: "Inspect repo")
        await fixture.controller.start()
        fixture.controller.setPreparationConfiguration(.defaultConfiguration)

        await fixture.controller.prepareWorkers(allowSkillChanges: true)

        XCTAssertEqual(preparer.lastActiveWorkerSurfaceIDs, [fixture.workerSurfaceID])
        XCTAssertEqual(fixture.controller.state.tasks.first?.status, .awaitingReport)
        XCTAssertEqual(fixture.controller.state.workers.first?.status, .awaitingReport)
    }
}

@MainActor
private final class AgentQueueControllerFixture {
    let now: Date = {
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 9, hour: 10, minute: 11, second: 12)
        )!
    }()
    let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let plannerSurfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let workerSurfaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let adapter = FakeAgentQueuePaneAdapter()
    let controller: AgentQueueController

    init(
        pollInterval: Duration = .seconds(1),
        prepared: Bool = true,
        additionalSkill: AgentQueueSkillSelection? = nil,
        configuration: AgentQueuePreparationConfiguration? = nil,
        includeWorker: Bool = true,
        store: AgentQueueStore? = nil,
        installer: (any AgentQueueRoleSkillInstalling)? = nil,
        preparer: (any AgentQueueWorkerPreparing)? = nil
    ) {
        let queue = AgentQueue(
            id: "queue-1",
            workspaceID: workspaceID,
            plannerSurfaceID: plannerSurfaceID,
            status: .paused,
            createdAt: now,
            updatedAt: now
        )
        let worker = AgentWorker(
            id: "worker-1",
            workspaceID: workspaceID,
            paneID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            surfaceID: workerSurfaceID,
            label: "Worker 1",
            enabled: true,
            status: .idle,
            currentTaskID: nil,
            lastSeenAt: now
        )
        let fixedNow = now
        let configuration = configuration ?? (try! AgentQueuePreparationConfiguration(
            workerCount: 1,
            additionalSkill: additionalSkill
        ))
        let preparation = AgentQueuePreparationState(
            configuration: configuration,
            phase: prepared ? .ready : .notPrepared,
            completedWorkerCount: prepared ? 1 : 0,
            errorMessage: nil
        )
        controller = AgentQueueController(
            initialState: AgentQueueState(
                queue: queue,
                tasks: [],
                workers: includeWorker ? [worker] : [],
                events: [],
                preparation: preparation
            ),
            paneAdapter: adapter,
            store: store,
            roleSkillInstaller: installer,
            workerPreparer: preparer,
            pollInterval: pollInterval,
            now: { fixedNow }
        )
    }
}

private final class FakeAgentQueuePaneAdapter: AgentQueuePaneAdapting, @unchecked Sendable {
    var sentTexts: [(surfaceID: UUID, text: String)] = []
    var enterSurfaces: [UUID] = []
    var textBySurface: [UUID: String] = [:]
    var enterError: Error?
    var readCount = 0
    var unavailableSurfaceIDs: Set<UUID> = []

    func sendText(_ text: String, to surfaceID: UUID) async throws -> AgentQueueSendResult {
        sentTexts.append((surfaceID, text))
        return AgentQueueSendResult(surfaceID: surfaceID, queued: false)
    }

    func sendEnter(to surfaceID: UUID) async throws -> AgentQueueSendResult {
        enterSurfaces.append(surfaceID)
        if let enterError {
            throw enterError
        }
        return AgentQueueSendResult(surfaceID: surfaceID, queued: false)
    }

    func readText(surfaceID: UUID, lines: Int) async throws -> AgentQueueSurfaceTextSnapshot {
        readCount += 1
        if unavailableSurfaceIDs.contains(surfaceID) {
            throw AgentQueuePaneAdapterError.surfaceNotTerminal(surfaceID)
        }
        return AgentQueueSurfaceTextSnapshot(
            surfaceID: surfaceID,
            text: textBySurface[surfaceID] ?? "",
            capturedAt: Date(timeIntervalSince1970: 1_782_998_400)
        )
    }
}

private actor FakeAgentQueueRoleSkillInstaller: AgentQueueRoleSkillInstalling {
    private var pending: [AgentQueueRoleSkillChange]
    private var applied: [AgentQueueRoleSkillChange] = []

    init(pending: [AgentQueueRoleSkillChange]) {
        self.pending = pending
    }

    func pendingChanges() async throws -> [AgentQueueRoleSkillChange] {
        pending
    }

    func apply(_ changes: [AgentQueueRoleSkillChange]) async throws {
        applied.append(contentsOf: changes)
        pending.removeAll()
    }

    func appliedRoles() -> [AgentQueueRoleSkill] {
        applied.map(\.role)
    }
}

@MainActor
private final class FakeAgentQueueWorkerPreparer: AgentQueueWorkerPreparing {
    var result: AgentQueuePreparedWorkspace
    var prepareCallCount = 0
    var lastActiveWorkerSurfaceIDs: Set<UUID> = []

    init(result: AgentQueuePreparedWorkspace) {
        self.result = result
    }

    func prepare(
        configuration: AgentQueuePreparationConfiguration,
        plannerSurfaceID: UUID,
        existingWorkerSurfaceIDs: [UUID],
        activeWorkerSurfaceIDs: Set<UUID>,
        progress: @escaping @MainActor (AgentQueuePreparationPhase, Int) -> Void
    ) async throws -> AgentQueuePreparedWorkspace {
        prepareCallCount += 1
        lastActiveWorkerSurfaceIDs = activeWorkerSurfaceIDs
        progress(.startingWorkers, 0)
        progress(.waitingForIdle, result.workerSurfaceIDs.count)
        return result
    }
}
