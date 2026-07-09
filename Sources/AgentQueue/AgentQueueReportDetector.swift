import Foundation

enum AgentQueueReportLocation: String, Codable, Equatable, Sendable {
    case planner
    case wrongPane
}

enum AgentQueueDetectedReportKind: String, Codable, Equatable, Sendable {
    case completed
    case blocked
    case running
    case unmatched
}

struct AgentQueueDetectedReport: Equatable, Sendable {
    var taskID: String
    var kind: AgentQueueDetectedReportKind
    var location: AgentQueueReportLocation
    var surfaceID: UUID
    var excerpt: String
}

enum AgentQueueReportDetector {
    private static let taskPattern = #"(?m)(완료 보고|자동 복구 보고|복구 요청 응답)?\s*\[(T-\d{8}-\d{4})\][^\n]*(?:\n[^\n]*){0,8}"#

    static func detect(
        in text: String,
        surfaceID: UUID,
        plannerSurfaceID: UUID,
        knownTaskIDs: Set<String>
    ) -> [AgentQueueDetectedReport] {
        guard let regex = try? NSRegularExpression(pattern: taskPattern) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)

        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let idRange = Range(match.range(at: 2), in: text),
                  let excerptRange = Range(match.range(at: 0), in: text) else {
                return nil
            }

            let taskID = String(text[idRange])
            let excerpt = String(text[excerptRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = reportKind(excerpt: excerpt, taskID: taskID, knownTaskIDs: knownTaskIDs)
            let location: AgentQueueReportLocation = surfaceID == plannerSurfaceID ? .planner : .wrongPane

            return AgentQueueDetectedReport(
                taskID: taskID,
                kind: kind,
                location: location,
                surfaceID: surfaceID,
                excerpt: excerpt
            )
        }
    }

    private static func reportKind(
        excerpt: String,
        taskID: String,
        knownTaskIDs: Set<String>
    ) -> AgentQueueDetectedReportKind {
        guard knownTaskIDs.contains(taskID) else {
            return .unmatched
        }

        let lower = excerpt.lowercased()
        if lower.contains("blocked:") || lower.contains("막힌 이유") {
            return .blocked
        }
        if lower.contains("running:") || lower.contains("진행 상황") {
            return .running
        }
        return .completed
    }
}
