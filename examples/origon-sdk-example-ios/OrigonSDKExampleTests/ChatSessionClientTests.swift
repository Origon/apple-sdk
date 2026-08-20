import XCTest
import OrigonSDK
@testable import OrigonSDKExample

@MainActor
final class ChatSessionClientTests: XCTestCase {
    func testCachedSnapshotPaintsBeforeNamedAccessAndCannotGrantSend() async throws {
        let fake = FakeLateChatClient()
        let service = ChatService(chatClient: fake)
        let task = Task { await service.openSession(id: "saved") }
        await fake.waitForRequests(1)

        fake.yield(snapshot(source: "cache", authoritative: false, messages: [message("cached")]), at: 0)
        await waitUntil { service.sessionsState["saved"]?.loadState == .cached }

        XCTAssertEqual(service.messages.map(\.id), ["cached"])
        XCTAssertFalse(service.canSendFocusedSession)
        XCTAssertEqual(fake.accesses.map(\.id), ["saved"])
        XCTAssertEqual(fake.accesses.map(\.intent), [.explicitNavigation])

        fake.finishStream(at: 0)
        fake.succeedAccess(at: 0)
        _ = await task.result
        XCTAssertTrue(service.canSendFocusedSession)
    }

    func testFreshEmptyAndTypedRefreshFailureRemainDistinct() async throws {
        let fake = FakeLateChatClient()
        let service = ChatService(chatClient: fake)
        let emptyTask = Task { await service.openSession(id: "empty") }
        await fake.waitForRequests(1)
        fake.yield(snapshot(source: "network", authoritative: true, messages: []), at: 0)
        fake.finishStream(at: 0)
        fake.succeedAccess(at: 0)
        _ = await emptyTask.result
        XCTAssertEqual(service.sessionsState["empty"]?.loadState, .freshEmpty)

        let failedTask = Task { await service.openSession(id: "offline") }
        await fake.waitForRequests(2)
        fake.yield(snapshot(source: "cache", authoritative: false, messages: [message("saved")]), at: 1)
        fake.failRefresh(cachedShown: true, at: 1)
        fake.finishStream(at: 1)
        fake.failAccess(at: 1)
        _ = await failedTask.result
        XCTAssertEqual(
            service.sessionsState["offline"]?.loadState,
            .refreshFailed(cachedShown: true)
        )
        XCTAssertFalse(service.sessionsState["offline"]?.accessGranted ?? true)
        XCTAssertEqual(service.sessionsState["offline"]?.messages.map(\.id), ["saved"])
    }

    func testRapidDestinationAndClientReplacementFenceLatePublication() async throws {
        let fake = FakeLateChatClient()
        let service = ChatService(chatClient: fake)
        let firstA = Task { await service.openSession(id: "a") }
        await fake.waitForRequests(1)
        let b = Task { await service.openSession(id: "b") }
        await fake.waitForRequests(2)
        let finalA = Task { await service.openSession(id: "a") }
        await fake.waitForRequests(3)

        fake.yield(snapshot(source: "network", authoritative: true, messages: [message("stale-a")]), at: 0)
        fake.finishStream(at: 0)
        fake.succeedAccess(at: 0)
        fake.yield(snapshot(source: "network", authoritative: true, messages: [message("stale-b")]), at: 1)
        fake.finishStream(at: 1)
        fake.succeedAccess(at: 1)
        fake.yield(snapshot(source: "network", authoritative: true, messages: [message("current-a")]), at: 2)
        fake.finishStream(at: 2)
        fake.succeedAccess(at: 2)
        _ = await (firstA.result, b.result, finalA.result)

        XCTAssertEqual(service.currentSessionId, "a")
        XCTAssertEqual(service.messages.map(\.id), ["current-a"])
        XCTAssertNil(service.sessionsState["b"]?.messages.first { $0.id == "stale-b" })

        let endpointTask = Task { await service.openSession(id: "endpoint-old") }
        await fake.waitForRequests(4)
        service.clientWillChange()
        fake.yield(snapshot(source: "network", authoritative: true, messages: [message("late")]), at: 3)
        fake.finishStream(at: 3)
        fake.succeedAccess(at: 3)
        _ = await endpointTask.result
        XCTAssertFalse(service.sessionsState["endpoint-old"]?.accessGranted ?? true)
        XCTAssertFalse(service.sessionsState["endpoint-old"]?.messages.contains { $0.id == "late" } ?? false)
    }

    func testCancelledDestinationCannotPublishLateResults() async throws {
        let fake = FakeLateChatClient()
        let service = ChatService(chatClient: fake)
        let task = Task { await service.openSession(id: "cancelled") }
        await fake.waitForRequests(1)
        task.cancel()
        fake.yield(snapshot(source: "network", authoritative: true, messages: [message("late")]), at: 0)
        fake.finishStream(at: 0)
        fake.succeedAccess(at: 0)
        _ = await task.result
        XCTAssertFalse(service.sessionsState["cancelled"]?.accessGranted ?? true)
        XCTAssertFalse(service.sessionsState["cancelled"]?.messages.contains { $0.id == "late" } ?? false)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 where !predicate() { await Task.yield() }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    private func message(_ id: String) -> Message {
        Message(id: id, text: id)
    }

    private func snapshot(
        source: String,
        authoritative: Bool,
        messages: [Message]
    ) -> SessionLoadUpdate {
        let encoded = try! JSONEncoder().encode(messages)
        let history = String(decoding: encoded, as: UTF8.self)
        let json = """
        {"source":"\(source)","authoritative":\(authoritative),"refreshedAt":1,
         "session":{"history":\(history),"control":"ai"}}
        """
        let value = try! JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        return .snapshot(value)
    }
}

private final class FakeLateChatClient: ChatSessionClient {
    struct Access {
        let id: String
        let intent: ChatAccessIntent
        let continuation: CheckedContinuation<StartSessionResponse, Error>
    }

    private(set) var streamIds: [String] = []
    private(set) var streams: [AsyncThrowingStream<SessionLoadUpdate, Error>.Continuation] = []
    private(set) var accesses: [Access] = []

    func sessionUpdates(
        id: String,
        policy: SessionLoadPolicy
    ) throws -> AsyncThrowingStream<SessionLoadUpdate, Error> {
        streamIds.append(id)
        return AsyncThrowingStream { continuation in
            self.streams.append(continuation)
        }
    }

    func acquireChatAccess(
        sessionId: String,
        intent: ChatAccessIntent
    ) async throws -> StartSessionResponse {
        try await withCheckedThrowingContinuation { continuation in
            accesses.append(Access(id: sessionId, intent: intent, continuation: continuation))
        }
    }

    func waitForRequests(_ count: Int) async {
        for _ in 0..<500 where streams.count < count || accesses.count < count {
            await Task.yield()
        }
        XCTAssertEqual(streams.count, count)
        XCTAssertEqual(accesses.count, count)
    }

    func yield(_ update: SessionLoadUpdate, at index: Int) { streams[index].yield(update) }
    func finishStream(at index: Int) { streams[index].finish() }

    func failRefresh(cachedShown: Bool, at index: Int) {
        streams[index].yield(.refreshFailed(
            error: OrigonError(kind: .other, message: "offline"),
            cachedSnapshotEmitted: cachedShown
        ))
    }

    func succeedAccess(at index: Int) {
        let id = accesses[index].id
        accesses[index].continuation.resume(
            returning: StartSessionResponse(sessionId: id, url: "https://example.invalid", token: "test")
        )
    }

    func failAccess(at index: Int) {
        accesses[index].continuation.resume(
            throwing: OrigonError(kind: .other, message: "unavailable")
        )
    }
}
