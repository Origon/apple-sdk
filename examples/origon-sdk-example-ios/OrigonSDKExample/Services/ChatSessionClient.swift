import OrigonSDK

/// The narrow SDK surface used by cache-first chat selection.
///
/// Keeping this app-owned seam separate from `OrigonClient` lets the example's
/// policy tests deterministically release late loader/open results without
/// replacing or extending the public SDK API.
protocol ChatSessionClient: AnyObject {
    func sessionUpdates(
        id: String,
        policy: SessionLoadPolicy
    ) throws -> AsyncThrowingStream<SessionLoadUpdate, Error>

    func acquireChatAccess(
        sessionId: String,
        intent: ChatAccessIntent
    ) async throws -> StartSessionResponse
}

extension OrigonClient: ChatSessionClient {
    func acquireChatAccess(
        sessionId: String,
        intent: ChatAccessIntent
    ) async throws -> StartSessionResponse {
        try await Task.detached {
            try self.openChat(sessionId: sessionId, intent: intent)
        }.value
    }
}
