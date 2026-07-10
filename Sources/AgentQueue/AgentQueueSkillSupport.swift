import Foundation

enum AgentQueueSkillPath {
    static func normalize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}

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

protocol AgentQueueRoleSkillInstalling: Sendable {
    func pendingChanges() async throws -> [AgentQueueRoleSkillChange]
    func apply(_ changes: [AgentQueueRoleSkillChange]) async throws
}

actor AgentQueueRoleSkillInstaller: AgentQueueRoleSkillInstalling {
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

    func pendingChanges() async throws -> [AgentQueueRoleSkillChange] {
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

    func apply(_ changes: [AgentQueueRoleSkillChange]) async throws {
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

struct AgentQueueSkillCatalog: Sendable {
    private let indexStore: TextBoxMentionIndexStore

    init(indexStore: TextBoxMentionIndexStore = .shared) {
        self.indexStore = indexStore
    }

    func options(rootDirectory: String?, query: String = "") async -> [AgentQueueSkillSelection] {
        let excludedNames = Set(AgentQueueRoleSkill.allCases.map(\.rawValue))
        let suggestions = await indexStore.skillSuggestions(
            rootDirectory: rootDirectory,
            query: query
        )

        var seenSourcePaths: Set<String> = []
        return suggestions.compactMap { suggestion in
            let name: String
            if suggestion.title.hasPrefix("$") {
                name = String(suggestion.title.dropFirst())
            } else {
                name = suggestion.title
            }
            guard !excludedNames.contains(name),
                  seenSourcePaths.insert(suggestion.subtitle).inserted else {
                return nil
            }
            return AgentQueueSkillSelection(
                name: name,
                sourcePath: suggestion.subtitle
            )
        }
    }
}

enum AgentQueueSkillPromptBuilder {
    static var plannerPrompt: String {
        "$\(AgentQueueRoleSkill.planner.rawValue)"
    }

    static func workerPrompt(additionalSkill: AgentQueueSkillSelection?) -> String {
        [
            "$\(AgentQueueRoleSkill.worker.rawValue)",
            additionalSkill?.invocation,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    static func workerPrompts(configuration: AgentQueuePreparationConfiguration) -> [String] {
        Array(
            repeating: workerPrompt(additionalSkill: configuration.additionalSkill),
            count: configuration.workerCount
        )
    }
}
