import Foundation

struct CmuxSurfaceClosedEvent: Sendable, Equatable {
    let workspaceID: UUID
    let surfaceID: UUID
    let paneID: UUID?
    let origin: String
}
