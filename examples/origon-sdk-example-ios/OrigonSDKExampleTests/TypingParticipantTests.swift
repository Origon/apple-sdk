import XCTest
import OrigonSDK
@testable import OrigonSDKExample

@MainActor
final class TypingParticipantTests: XCTestCase {
    func testNamedAgentAndUnnamedAgentResolveWithoutTranscriptInference() {
        let named = TypingParticipant(
            participantId: "p1", role: .user, userId: "u1", userName: "Sam", audience: .all
        )
        XCTAssertEqual(exampleTypingAuthor(named), .init(key: "agent:u1", displayName: "Sam"))

        let unnamed = TypingParticipant(participantId: "p2", role: .user, audience: .internalParticipants)
        XCTAssertEqual(exampleTypingAuthor(unnamed).displayName, "Agent")
    }

    func testFlowAndEmptySnapshotUseAssistantFallback() {
        let flow = TypingParticipant(participantId: "flow", role: .system, audience: .all)
        XCTAssertEqual(exampleTypingAuthor(flow).displayName, "Assistant")
        XCTAssertEqual(exampleTypingAuthor(nil).displayName, "Assistant")
    }

    func testTerminalEventClearsTypingSnapshot() {
        let service = ChatService()
        let participant = TypingParticipant(
            participantId: "p1", role: .user, userId: "u1", userName: "Sam", audience: .all
        )
        service.installStateForTesting(id: "chat", state: .init())
        service.receiveForTesting(.typing(
            sessionId: "chat", state: .init(participants: [participant])
        ))
        XCTAssertTrue(service.isTyping)
        XCTAssertEqual(service.typingParticipant, participant)

        service.receiveForTesting(.chatSessionEnded(
            sessionId: "chat", reason: "complete", acw: nil
        ))

        XCTAssertFalse(service.isTyping)
        XCTAssertNil(service.typingParticipant)
        XCTAssertTrue(service.sessionsState["chat"]?.typingState.participants.isEmpty == true)
    }
}
