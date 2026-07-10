import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class AgentQueuePreparationTests: XCTestCase {
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
        XCTAssertEqual(try await installer.pendingChanges(), [])
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
