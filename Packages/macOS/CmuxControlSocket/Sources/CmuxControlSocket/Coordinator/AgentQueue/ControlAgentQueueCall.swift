public import Foundation

/// A validated Agent Queue JSON-RPC call passed from the socket package to the
/// app-owned queue coordinator.
public struct ControlAgentQueueCall: Sendable, Equatable {
    /// JSON-RPC method name.
    public let method: String
    /// Workspace supplied by the calling terminal environment.
    public let workspaceID: UUID
    /// Surface supplied by the calling terminal environment.
    public let surfaceID: UUID
    /// Method-specific parameters, excluding caller routing identifiers.
    public let params: [String: JSONValue]

    /// Creates a validated Agent Queue call.
    ///
    /// - Parameters:
    ///   - method: JSON-RPC method name.
    ///   - workspaceID: Calling workspace identifier.
    ///   - surfaceID: Calling surface identifier.
    ///   - params: Method-specific parameters.
    public init(
        method: String,
        workspaceID: UUID,
        surfaceID: UUID,
        params: [String: JSONValue]
    ) {
        self.method = method
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.params = params
    }
}
