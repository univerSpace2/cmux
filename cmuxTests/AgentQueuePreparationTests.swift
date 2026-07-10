import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentQueuePreparationTests: XCTestCase {
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
}
