import XCTest
import OrigonSDK
@testable import OrigonSDKExample

final class ChatSessionClientTests: XCTestCase {
    func testFakeStreamCanReleaseAResultAfterTheConsumerStarts() async throws {
        let fake = FakeLateChatClient()
        let stream = try fake.sessionUpdates(id: "session-a", policy: .cacheThenNetwork)
        let finished = expectation(description: "late stream finished")

        let task = Task {
            do {
                for try await _ in stream {}
            } catch {
                XCTFail("unexpected stream error: \(error)")
            }
            finished.fulfill()
        }

        XCTAssertEqual(fake.requestedSessionIds, ["session-a"])
        fake.finishLate()
        await fulfillment(of: [finished], timeout: 1)
        _ = await task.result
    }
}

private final class FakeLateChatClient: ChatSessionClient {
    private(set) var requestedSessionIds: [String] = []
    private var continuation: AsyncThrowingStream<SessionLoadUpdate, Error>.Continuation?

    func sessionUpdates(
        id: String,
        policy: SessionLoadPolicy
    ) throws -> AsyncThrowingStream<SessionLoadUpdate, Error> {
        requestedSessionIds.append(id)
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func openChat(
        sessionId: String,
        intent: ChatAccessIntent
    ) throws -> StartSessionResponse {
        throw FakeError.notConfigured
    }

    func finishLate() {
        continuation?.finish()
    }

    private enum FakeError: Error {
        case notConfigured
    }
}
