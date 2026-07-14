/// Async app seam for Agent Queue commands parsed on the socket-worker lane.
///
/// The package validates transport shapes only. The app implementation owns
/// queue authorization, durable mutation, and result mapping.
public protocol ControlAgentQueueContext: AnyObject, Sendable {
    /// Routes one validated call into the app-owned Agent Queue coordinator.
    ///
    /// - Parameter call: Validated caller context and method payload.
    /// - Returns: Structured JSON-RPC result.
    nonisolated func controlAgentQueue(
        _ call: ControlAgentQueueCall
    ) async -> ControlCallResult
}
