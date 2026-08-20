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

    func openChat(
        sessionId: String,
        intent: ChatAccessIntent
    ) throws -> StartSessionResponse
}

extension OrigonClient: ChatSessionClient {}
