import Foundation

enum AgentQueueRoleSkill: String, CaseIterable, Equatable, Sendable {
    case planner = "cmux-agent-queue-planner"
    case worker = "cmux-agent-queue-worker"

    fileprivate func skillURL(root: URL) -> URL {
        root
            .appendingPathComponent(rawValue, isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }
}

struct AgentQueueRoleSkillChange: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case install
        case update
    }

    var role: AgentQueueRoleSkill
    var sourceURL: URL
    var destinationURL: URL
    var kind: Kind
}

actor AgentQueueRoleSkillInstaller {
    private let sourceRoot: URL?
    private let destinationRoot: URL
    private let fileManager: FileManager

    init(
        sourceRoot: URL? = nil,
        destinationRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/skills", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.sourceRoot = sourceRoot ?? Bundle.main.resourceURL
        self.destinationRoot = destinationRoot
        self.fileManager = fileManager
    }

    func pendingChanges() throws -> [AgentQueueRoleSkillChange] {
        guard let sourceRoot else {
            throw missingFileError(path: "Bundle.main.resourceURL")
        }

        return try AgentQueueRoleSkill.allCases.compactMap { role in
            let sourceURL = role.skillURL(root: sourceRoot)
            let destinationURL = role.skillURL(root: destinationRoot)
            let sourceData = try Data(contentsOf: sourceURL)

            guard fileManager.fileExists(atPath: destinationURL.path) else {
                return AgentQueueRoleSkillChange(
                    role: role,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    kind: .install
                )
            }

            let destinationData = try Data(contentsOf: destinationURL)
            guard sourceData != destinationData else { return nil }
            return AgentQueueRoleSkillChange(
                role: role,
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                kind: .update
            )
        }
    }

    func apply(_ changes: [AgentQueueRoleSkillChange]) throws {
        guard let sourceRoot else {
            throw missingFileError(path: "Bundle.main.resourceURL")
        }

        for change in changes {
            let sourceURL = change.role.skillURL(root: sourceRoot)
            let destinationURL = change.role.skillURL(root: destinationRoot)
            guard change.sourceURL.standardizedFileURL == sourceURL.standardizedFileURL,
                  change.destinationURL.standardizedFileURL == destinationURL.standardizedFileURL else {
                throw invalidChangeError(path: change.destinationURL.path)
            }

            let data = try Data(contentsOf: sourceURL)
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destinationURL, options: .atomic)
        }
    }

    private func missingFileError(path: String) -> NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileNoSuchFileError,
            userInfo: [NSFilePathErrorKey: path]
        )
    }

    private func invalidChangeError(path: String) -> NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteInvalidFileNameError,
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}

