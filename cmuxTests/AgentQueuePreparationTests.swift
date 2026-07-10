import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentQueuePreparationTests: XCTestCase {
    @MainActor
    func testPlainIdlePlannerLaunchesCodexBeforeApplyingPlannerRole() async throws {
        let planner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let worker = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let driver = FakeAgentQueueWorkspaceDriver(
            plannerSurfaceID: planner,
            createdWorkerSurfaceIDs: [worker]
        )
        driver.readinessSequences[planner] = [.absent, .starting, .idle, .busy, .idle]
        driver.readinessSequences[worker] = [.starting, .idle, .busy, .idle]
        let service = makePreparationService(driver: driver)

        _ = try await service.prepare(
            configuration: .defaultConfiguration,
            plannerSurfaceID: planner,
            existingWorkerSurfaceIDs: [],
            activeWorkerSurfaceIDs: [],
            progress: { _, _ in }
        )

        XCTAssertEqual(driver.sentTexts.first?.surfaceID, planner)
        XCTAssertEqual(driver.sentTexts.first?.text, "codex")
        XCTAssertTrue(driver.sentTexts.contains { item in
            item.surfaceID == planner && item.text == "$cmux-agent-queue-planner"
        })
    }

    @MainActor
    func testIdleCodexPlannerIsReusedWithoutLaunchingAnotherProcess() async throws {
        let planner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let worker = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let driver = FakeAgentQueueWorkspaceDriver(
            plannerSurfaceID: planner,
            createdWorkerSurfaceIDs: [worker]
        )
        driver.readinessSequences[planner] = [.idle, .busy, .idle]
        driver.readinessSequences[worker] = [.starting, .idle, .busy, .idle]

        _ = try await makePreparationService(driver: driver).prepare(
            configuration: .defaultConfiguration,
            plannerSurfaceID: planner,
            existingWorkerSurfaceIDs: [],
            activeWorkerSurfaceIDs: [],
            progress: { _, _ in }
        )

        XCTAssertFalse(driver.sentTexts.contains { $0.surfaceID == planner && $0.text == "codex" })
        XCTAssertEqual(
            driver.sentTexts.filter { $0.surfaceID == planner }.map(\.text),
            ["$cmux-agent-queue-planner"]
        )
    }

    @MainActor
    func testBusyPlannerFailsWithoutSendingInputOrCreatingWorkers() async {
        let planner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let driver = FakeAgentQueueWorkspaceDriver(plannerSurfaceID: planner)
        driver.readinessSequences[planner] = [.busy]

        do {
            _ = try await makePreparationService(driver: driver).prepare(
                configuration: .defaultConfiguration,
                plannerSurfaceID: planner,
                existingWorkerSurfaceIDs: [],
                activeWorkerSurfaceIDs: [],
                progress: { _, _ in }
            )
            XCTFail("Expected busy planner to fail")
        } catch {
            XCTAssertEqual(error as? AgentQueuePreparationError, .plannerBusy)
        }

        XCTAssertTrue(driver.sentTexts.isEmpty)
        XCTAssertTrue(driver.createdSplits.isEmpty)
    }

    @MainActor
    func testDefaultPreparationCreatesOneUnfocusedRightShellSplitThenLaunchesCodex() async throws {
        let planner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let worker = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let driver = FakeAgentQueueWorkspaceDriver(
            plannerSurfaceID: planner,
            workingDirectory: "/tmp/project",
            createdWorkerSurfaceIDs: [worker]
        )
        driver.readinessSequences[planner] = [.idle, .busy, .idle]
        driver.readinessSequences[worker] = [.starting, .idle, .busy, .idle]

        let prepared = try await makePreparationService(driver: driver).prepare(
            configuration: .defaultConfiguration,
            plannerSurfaceID: planner,
            existingWorkerSurfaceIDs: [],
            activeWorkerSurfaceIDs: [],
            progress: { _, _ in }
        )

        XCTAssertEqual(driver.createdSplits, [
            AgentQueueWorkerSplitRequest(
                sourceSurfaceID: planner,
                direction: .right,
                focus: false,
                workingDirectory: "/tmp/project",
                initialCommand: ""
            ),
        ])
        XCTAssertEqual(
            driver.sentTexts.filter { $0.surfaceID == worker }.map(\.text),
            ["codex", "$cmux-agent-queue-worker"]
        )
        XCTAssertEqual(prepared.workerSurfaceIDs, [worker])
        XCTAssertEqual(prepared.workingDirectory, "/tmp/project")
    }

    @MainActor
    func testNewWorkerLaunchesCodexAfterItsShellIsReady() async throws {
        let planner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let worker = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let driver = FakeAgentQueueWorkspaceDriver(
            plannerSurfaceID: planner,
            createdWorkerSurfaceIDs: [worker]
        )
        driver.createdWorkerShellActivity = .promptIdle
        driver.readinessSequences[planner] = [.idle, .busy, .idle]
        driver.readinessSequences[worker] = [.absent, .starting, .idle, .busy, .idle]

        _ = try await makePreparationService(driver: driver).prepare(
            configuration: .defaultConfiguration,
            plannerSurfaceID: planner,
            existingWorkerSurfaceIDs: [],
            activeWorkerSurfaceIDs: [],
            progress: { _, _ in }
        )

        XCTAssertEqual(
            driver.sentTexts.filter { $0.surfaceID == worker }.map(\.text),
            ["codex", "$cmux-agent-queue-worker"]
        )
    }

    @MainActor
    func testPreparationAppliesSameOptionalSkillToEveryWorker() async throws {
        let planner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let firstWorker = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let secondWorker = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let driver = FakeAgentQueueWorkspaceDriver(
            plannerSurfaceID: planner,
            createdWorkerSurfaceIDs: [firstWorker, secondWorker]
        )
        driver.readinessSequences[planner] = [.idle, .busy, .idle]
        driver.readinessSequences[firstWorker] = [.starting, .idle, .busy, .idle]
        driver.readinessSequences[secondWorker] = [.starting, .idle, .busy, .idle]
        let configuration = try AgentQueuePreparationConfiguration(
            workerCount: 2,
            additionalSkill: AgentQueueSkillSelection(
                name: "sample-domain-skill",
                sourcePath: "/tmp/sample-domain-skill/SKILL.md"
            )
        )

        _ = try await makePreparationService(driver: driver).prepare(
            configuration: configuration,
            plannerSurfaceID: planner,
            existingWorkerSurfaceIDs: [],
            activeWorkerSurfaceIDs: [],
            progress: { _, _ in }
        )

        for worker in [firstWorker, secondWorker] {
            XCTAssertEqual(
                driver.sentTexts.filter { $0.surfaceID == worker }.map(\.text),
                ["codex", "$cmux-agent-queue-worker $sample-domain-skill"]
            )
        }
    }

    @MainActor
    func testReadinessTimeoutNamesTheSurface() async {
        let planner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let driver = FakeAgentQueueWorkspaceDriver(plannerSurfaceID: planner)
        driver.readinessSequences[planner] = [.absent, .starting]
        let service = AgentQueueWorkerPreparationService(
            driver: driver,
            readinessTimeout: .zero,
            pollInterval: .zero,
            sleep: { _ in }
        )

        do {
            _ = try await service.prepare(
                configuration: .defaultConfiguration,
                plannerSurfaceID: planner,
                existingWorkerSurfaceIDs: [],
                activeWorkerSurfaceIDs: [],
                progress: { _, _ in }
            )
            XCTFail("Expected readiness timeout")
        } catch {
            XCTAssertEqual(error as? AgentQueuePreparationError, .codexReadinessTimedOut(planner))
        }
    }

    @MainActor
    func testReducingWorkersClosesOnlyReconciliationPlanSurplus() async throws {
        let planner = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let keepWorker = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let closeWorker = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let unrelated = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        let driver = FakeAgentQueueWorkspaceDriver(plannerSurfaceID: planner)
        driver.terminalSurfaceIDs.formUnion([keepWorker, closeWorker, unrelated])
        driver.readinessSequences[planner] = [.idle, .busy, .idle]
        driver.readinessSequences[keepWorker] = [.idle, .busy, .idle]

        let prepared = try await makePreparationService(driver: driver).prepare(
            configuration: .defaultConfiguration,
            plannerSurfaceID: planner,
            existingWorkerSurfaceIDs: [keepWorker, closeWorker],
            activeWorkerSurfaceIDs: [],
            progress: { _, _ in }
        )

        XCTAssertEqual(driver.closedSurfaceIDs, [closeWorker])
        XCTAssertFalse(driver.closedSurfaceIDs.contains(unrelated))
        XCTAssertEqual(prepared.workerSurfaceIDs, [keepWorker])
    }

    func testPreparationConfigurationDefaultsToOneWorkerAndRejectsOutOfRangeCounts() throws {
        XCTAssertEqual(AgentQueuePreparationConfiguration.defaultConfiguration.workerCount, 1)
        XCTAssertNil(AgentQueuePreparationConfiguration.defaultConfiguration.additionalSkill)

        for invalidCount in [0, 5] {
            XCTAssertThrowsError(
                try AgentQueuePreparationConfiguration(
                    workerCount: invalidCount,
                    additionalSkill: nil
                )
            ) { error in
                XCTAssertEqual(error as? AgentQueuePreparationError, .invalidWorkerCount(invalidCount))
            }
        }
    }

    func testConfigurationOwnsPlannerAndFourStableWorkerProfiles() {
        let configuration = AgentQueuePreparationConfiguration.defaultConfiguration

        XCTAssertEqual(configuration.workerCount, 1)
        XCTAssertEqual(configuration.plannerProfile.id, "planner")
        XCTAssertEqual(
            configuration.workerProfiles.map(\.id),
            ["worker-1", "worker-2", "worker-3", "worker-4"]
        )
        XCTAssertEqual(configuration.activeAgentIDs, ["planner", "worker-1"])
    }

    func testReducingAndIncreasingWorkerCountPreservesHiddenProfile() throws {
        let skill = AgentQueueSkillSelection(
            name: "api-integration",
            sourcePath: "/tmp/skills/api-integration/SKILL.md"
        )
        var workerTwo = AgentQueueAgentProfile.worker(index: 1)
        workerTwo = workerTwo.addingSkill(skill)
        workerTwo.rolePrompt = "Own API integration and verification."
        var configuration = try AgentQueuePreparationConfiguration(
            workerCount: 2,
            plannerProfile: .planner,
            workerProfiles: AgentQueueAgentProfile.defaultWorkers
        ).replacingProfile(workerTwo)

        configuration = try configuration.replacingWorkerCount(1)
        configuration = try configuration.replacingWorkerCount(2)

        XCTAssertEqual(configuration.profile(id: "worker-2"), workerTwo)
    }

    func testProfileDeduplicatesStandardizedSkillPathsAndKeepsInsertionOrder() {
        let first = AgentQueueSkillSelection(
            name: "api-integration",
            sourcePath: "/tmp/skills/api-integration/SKILL.md"
        )
        let duplicate = AgentQueueSkillSelection(
            name: "api-integration-copy",
            sourcePath: "/tmp/skills/../skills/api-integration/SKILL.md"
        )
        let second = AgentQueueSkillSelection(
            name: "careful",
            sourcePath: "/tmp/skills/careful/SKILL.md"
        )

        let profile = AgentQueueAgentProfile.worker(index: 0)
            .addingSkill(first)
            .addingSkill(duplicate)
            .addingSkill(second)

        XCTAssertEqual(profile.additionalSkills, [first, second])
    }

    func testPreparationSnapshotDefaultsToOneWorkerWithNoAdditionalSkillAndDisabledStart() {
        let snapshot = AgentQueuePreparationSnapshot(preparation: nil, canStart: false)

        XCTAssertEqual(snapshot.workerCount, 1)
        XCTAssertEqual(
            snapshot.additionalSkillText,
            String(localized: "agentQueue.preparation.skill.none", defaultValue: "None")
        )
        XCTAssertTrue(snapshot.isStartDisabled)
        XCTAssertNil(snapshot.progressText)
    }

    func testPreparationSnapshotShowsWorkerProgressAndRetryForFailure() throws {
        let progress = AgentQueuePreparationSnapshot(
            preparation: AgentQueuePreparationState(
                configuration: try AgentQueuePreparationConfiguration(
                    workerCount: 3,
                    additionalSkill: nil
                ),
                phase: .waitingForIdle,
                completedWorkerCount: 2,
                errorMessage: nil
            ),
            canStart: false
        )
        let failed = AgentQueuePreparationSnapshot(
            preparation: AgentQueuePreparationState(
                configuration: .defaultConfiguration,
                phase: .failed,
                completedWorkerCount: 0,
                errorMessage: "planner unavailable"
            ),
            canStart: false
        )

        XCTAssertTrue(progress.progressText?.contains("2/3") == true)
        XCTAssertFalse(progress.showsRetry)
        XCTAssertTrue(failed.showsRetry)
        XCTAssertEqual(failed.errorMessage, "planner unavailable")
    }

    func testSkillRowSnapshotUsesStableSourcePathIdentity() {
        let selection = AgentQueueSkillSelection(
            name: "sample-domain-skill",
            sourcePath: "/tmp/sample-domain-skill/SKILL.md"
        )

        let row = AgentQueueSkillRowSnapshot(selection: selection)

        XCTAssertEqual(row.id, selection.sourcePath)
        XCTAssertEqual(row.name, "sample-domain-skill")
        XCTAssertEqual(row.sourcePath, selection.sourcePath)
    }

    func testSkillCatalogExcludesMandatoryRoles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-queue-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in [
            "cmux-agent-queue-planner",
            "cmux-agent-queue-worker",
            "sample-domain-skill",
        ] {
            let directory = root
                .appendingPathComponent("skills", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: Use when testing.\n---\n".write(
                to: directory.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        let options = await AgentQueueSkillCatalog().options(rootDirectory: root.path, query: "")

        XCTAssertTrue(options.contains { $0.name == "sample-domain-skill" })
        XCTAssertFalse(options.contains { $0.name == "cmux-agent-queue-planner" })
        XCTAssertFalse(options.contains { $0.name == "cmux-agent-queue-worker" })
        XCTAssertTrue(options.first { $0.name == "sample-domain-skill" }?.sourcePath.contains(root.path) == true)
    }

    func testSelectedSkillIsAppliedToEveryWorkerPrompt() throws {
        let selectedSkill = AgentQueueSkillSelection(
            name: "sample-domain-skill",
            sourcePath: "/tmp/skills/sample-domain-skill/SKILL.md"
        )
        let configuration = try AgentQueuePreparationConfiguration(
            workerCount: 3,
            additionalSkill: selectedSkill
        )

        let prompts = AgentQueueSkillPromptBuilder.workerPrompts(configuration: configuration)

        XCTAssertEqual(prompts.count, 3)
        XCTAssertEqual(Set(prompts), ["$cmux-agent-queue-worker $sample-domain-skill"])
    }

    func testWorkerReconcilerCreatesOnlyDeficitAndClosesStableSurplus() throws {
        let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let third = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        let increase = try AgentQueueWorkerReconciler.plan(
            existingWorkerSurfaceIDs: [first],
            requestedCount: 3,
            activeWorkerSurfaceIDs: []
        )
        XCTAssertEqual(increase.keep, [first])
        XCTAssertEqual(increase.createCount, 2)
        XCTAssertEqual(increase.close, [])

        let reduce = try AgentQueueWorkerReconciler.plan(
            existingWorkerSurfaceIDs: [first, second, third],
            requestedCount: 2,
            activeWorkerSurfaceIDs: []
        )
        XCTAssertEqual(reduce.keep, [first, second])
        XCTAssertEqual(reduce.createCount, 0)
        XCTAssertEqual(reduce.close, [third])
    }

    func testWorkerReconcilerRejectsClosingActiveWorker() {
        let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        XCTAssertThrowsError(
            try AgentQueueWorkerReconciler.plan(
                existingWorkerSurfaceIDs: [first, second],
                requestedCount: 1,
                activeWorkerSurfaceIDs: [second]
            )
        ) { error in
            XCTAssertEqual(error as? AgentQueuePreparationError, .activeWorkerWouldClose(second))
        }
    }

    func testCanonicalRoleSkillsDeclareNamesAndQueueContracts() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plannerURL = repositoryRoot
            .appendingPathComponent("skills/cmux-agent-queue-planner/SKILL.md")
        let workerURL = repositoryRoot
            .appendingPathComponent("skills/cmux-agent-queue-worker/SKILL.md")

        let planner = try String(contentsOf: plannerURL, encoding: .utf8)
        let worker = try String(contentsOf: workerURL, encoding: .utf8)

        XCTAssertEqual(frontmatterName(in: planner), "cmux-agent-queue-planner")
        XCTAssertEqual(frontmatterName(in: worker), "cmux-agent-queue-worker")
        XCTAssertTrue(planner.contains("Agent Queue is the dispatch authority"))
        XCTAssertTrue(worker.contains("완료 보고 [T-YYYYMMDD-NNNN]"))
        XCTAssertTrue(worker.contains("Do not use `cmux send` for ordinary completion"))
        XCTAssertTrue(worker.contains("Do not look up planner refs"))
    }

    func testRoleSkillInstallerInstallsSkipsAndUpdatesOnlyRoleSkills() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-queue-role-skills-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeRoleSkill(.planner, contents: "planner-v1", root: sourceRoot)
        try writeRoleSkill(.worker, contents: "worker-v1", root: sourceRoot)
        let installer = AgentQueueRoleSkillInstaller(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot
        )

        let installs = try await installer.pendingChanges()
        XCTAssertEqual(installs.map(\.role), [.planner, .worker])
        XCTAssertEqual(installs.map(\.kind), [.install, .install])

        try await installer.apply(installs)
        let noChanges = try await installer.pendingChanges()
        XCTAssertEqual(noChanges, [])
        XCTAssertEqual(
            try String(contentsOf: roleSkillURL(.worker, root: destinationRoot), encoding: .utf8),
            "worker-v1"
        )

        try writeRoleSkill(.worker, contents: "worker-v2", root: sourceRoot)
        let updates = try await installer.pendingChanges()
        XCTAssertEqual(updates.map(\.role), [.worker])
        XCTAssertEqual(updates.map(\.kind), [.update])

        try await installer.apply(updates)
        XCTAssertEqual(
            try String(contentsOf: roleSkillURL(.worker, root: destinationRoot), encoding: .utf8),
            "worker-v2"
        )
        XCTAssertEqual(
            try String(contentsOf: roleSkillURL(.planner, root: destinationRoot), encoding: .utf8),
            "planner-v1"
        )
    }

    private func frontmatterName(in contents: String) -> String? {
        contents.components(separatedBy: .newlines)
            .prefix { $0 != "---" || $0 == contents.components(separatedBy: .newlines).first }
            .first { $0.hasPrefix("name:") }?
            .dropFirst("name:".count)
            .trimmingCharacters(in: .whitespaces)
    }

    private func writeRoleSkill(
        _ role: AgentQueueRoleSkill,
        contents: String,
        root: URL
    ) throws {
        let url = roleSkillURL(role, root: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    private func roleSkillURL(_ role: AgentQueueRoleSkill, root: URL) -> URL {
        root
            .appendingPathComponent(role.rawValue, isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    @MainActor
    private func makePreparationService(
        driver: FakeAgentQueueWorkspaceDriver
    ) -> AgentQueueWorkerPreparationService {
        AgentQueueWorkerPreparationService(
            driver: driver,
            readinessTimeout: .seconds(1),
            pollInterval: .zero,
            sleep: { _ in }
        )
    }
}

@MainActor
private final class FakeAgentQueueWorkspaceDriver: AgentQueueWorkspaceDriving {
    var terminalSurfaceIDs: Set<UUID>
    var shellActivityBySurface: [UUID: AgentQueueShellActivity]
    var readinessSequences: [UUID: [AgentQueueCodexReadiness]] = [:]
    var sentTexts: [(surfaceID: UUID, text: String)] = []
    var enterSurfaceIDs: [UUID] = []
    var createdSplits: [AgentQueueWorkerSplitRequest] = []
    var closedSurfaceIDs: [UUID] = []
    var createdWorkerSurfaceIDs: [UUID]
    var createdWorkerShellActivity: AgentQueueShellActivity = .promptIdle
    let workingDirectory: String

    init(
        plannerSurfaceID: UUID,
        workingDirectory: String = "/tmp/project",
        createdWorkerSurfaceIDs: [UUID] = []
    ) {
        terminalSurfaceIDs = [plannerSurfaceID]
        shellActivityBySurface = [plannerSurfaceID: .promptIdle]
        self.workingDirectory = workingDirectory
        self.createdWorkerSurfaceIDs = createdWorkerSurfaceIDs
    }

    func isTerminalSurface(_ surfaceID: UUID) -> Bool {
        terminalSurfaceIDs.contains(surfaceID)
    }

    func shellActivity(surfaceID: UUID) -> AgentQueueShellActivity {
        shellActivityBySurface[surfaceID] ?? .unknown
    }

    func createWorkerSplit(_ request: AgentQueueWorkerSplitRequest) -> UUID? {
        createdSplits.append(request)
        guard !createdWorkerSurfaceIDs.isEmpty else { return nil }
        let surfaceID = createdWorkerSurfaceIDs.removeFirst()
        terminalSurfaceIDs.insert(surfaceID)
        shellActivityBySurface[surfaceID] = createdWorkerShellActivity
        return surfaceID
    }

    func closeWorkerSurface(_ surfaceID: UUID) -> Bool {
        closedSurfaceIDs.append(surfaceID)
        terminalSurfaceIDs.remove(surfaceID)
        return true
    }

    func codexReadiness(surfaceID: UUID) async -> AgentQueueCodexReadiness {
        guard var sequence = readinessSequences[surfaceID], let first = sequence.first else {
            return .idle
        }
        if sequence.count > 1 {
            sequence.removeFirst()
            readinessSequences[surfaceID] = sequence
        }
        return first
    }

    func sendText(_ text: String, to surfaceID: UUID) async throws {
        sentTexts.append((surfaceID, text))
    }

    func sendEnter(to surfaceID: UUID) async throws {
        enterSurfaceIDs.append(surfaceID)
    }
}
