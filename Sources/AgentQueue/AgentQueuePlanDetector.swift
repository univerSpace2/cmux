import Foundation

enum AgentQueuePlanDetector {
    private static let openingMarker = "[AGENT_QUEUE_TASKS]"
    private static let closingMarker = "[/AGENT_QUEUE_TASKS]"

    static func detect(
        in text: String
    ) -> Result<AgentQueuePlannedTasks, AgentQueuePlanDetectionError>? {
        guard
            let closingRange = text.range(of: closingMarker, options: .backwards),
            let openingRange = text.range(
                of: openingMarker,
                options: .backwards,
                range: text.startIndex..<closingRange.lowerBound
            )
        else {
            return nil
        }

        let payloadText = String(text[openingRange.upperBound..<closingRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = decodePayload(from: payloadText) else {
            return .failure(.malformedJSON)
        }

        guard !payload.tasks.isEmpty else {
            return .failure(.emptyTasks)
        }

        var tasks: [AgentQueuePlannedTask] = []
        tasks.reserveCapacity(payload.tasks.count)
        for (index, task) in payload.tasks.enumerated() {
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = task.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !body.isEmpty else {
                return .failure(.invalidTask(index: index))
            }
            tasks.append(AgentQueuePlannedTask(title: title, body: body))
        }

        return .success(AgentQueuePlannedTasks(
            requestID: payload.requestID,
            tasks: tasks
        ))
    }

    private static func decodePayload(from text: String) -> Payload? {
        let decoder = JSONDecoder()
        func decode(_ candidate: String) -> Payload? {
            try? decoder.decode(Payload.self, from: Data(candidate.utf8))
        }

        if let payload = decode(text) {
            return payload
        }

        let joined = joinTerminalWrappedLines(text, restoringLegacyWordSpaces: false)
        if let payload = decode(joined), payload.spaceEncoding == "unicode_escape" {
            return payload
        }

        let legacyRepaired = joinTerminalWrappedLines(text, restoringLegacyWordSpaces: true)
        if let payload = decode(legacyRepaired) {
            return payload
        }

        return decode(joined)
    }

    /// Codex redraws long TUI rows with physical newlines, so terminal text can
    /// split JSON strings even though the submitted response was one logical
    /// line. New protocol responses escape semantic spaces and can be joined
    /// byte-for-byte. The legacy fallback restores an ASCII word boundary only
    /// inside title/body values, while identifiers and JSON keys stay intact.
    private static func joinTerminalWrappedLines(
        _ text: String,
        restoringLegacyWordSpaces: Bool
    ) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.count > 1 else { return text }

        let horizontalWhitespace = CharacterSet(charactersIn: " \t")
        var result = ""
        var lexer = JSONStringLexer()

        for (index, line) in lines.enumerated() {
            let fragment = line.trimmingCharacters(in: horizontalWhitespace)
            if index > 0,
               restoringLegacyWordSpaces,
               lexer.isInsideTaskTextValue,
               shouldRestoreLegacyWordSpace(
                   before: result.last,
                   after: fragment.first
               ) {
                result.append(" ")
                lexer.consume(" ")
            }

            for character in fragment {
                result.append(character)
                lexer.consume(character)
            }
        }

        return result
    }

    private static func shouldRestoreLegacyWordSpace(
        before: Character?,
        after: Character?
    ) -> Bool {
        guard let before, let after else { return false }
        return isASCIIWordCharacter(before) && isASCIIWordCharacter(after)
    }

    private static func isASCIIWordCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (48 ... 57).contains(value)
            || (65 ... 90).contains(value)
            || (97 ... 122).contains(value)
    }
}

private struct JSONStringLexer {
    private var inString = false
    private var escaping = false
    private var currentString = ""
    private var lastCompletedString: String?
    private var lastSignificantOutsideCharacter: Character?
    private var activeValueKey: String?

    var isInsideTaskTextValue: Bool {
        inString && (activeValueKey == "title" || activeValueKey == "body")
    }

    mutating func consume(_ character: Character) {
        if inString {
            if escaping {
                currentString.append(character)
                escaping = false
            } else if character == "\\" {
                currentString.append(character)
                escaping = true
            } else if character == "\"" {
                inString = false
                lastCompletedString = currentString
                currentString = ""
                activeValueKey = nil
                lastSignificantOutsideCharacter = character
            } else {
                currentString.append(character)
            }
            return
        }

        if character == "\"" {
            inString = true
            currentString = ""
            activeValueKey = lastSignificantOutsideCharacter == ":"
                ? lastCompletedString
                : nil
        } else if !character.isWhitespace {
            lastSignificantOutsideCharacter = character
        }
    }
}

private struct Payload: Decodable {
    var spaceEncoding: String?
    var requestID: UUID
    var tasks: [Task]

    enum CodingKeys: String, CodingKey {
        case spaceEncoding = "space_encoding"
        case requestID = "request_id"
        case tasks
    }

    struct Task: Decodable {
        var title: String
        var body: String
    }
}
