import XCTest
@testable import OrigonSDK

final class TypingStateTests: XCTestCase {
    func testCanonicalTypingStateJSONRoundTripsInStableOrder() throws {
        let json = #"{"participants":[{"participantId":"supervisor-1","role":"user","userId":"u1","userName":"Sam","audience":"internal"},{"participantId":"flow","role":"system","audience":"all"}]}"#
        let decoded = try JSONDecoder().decode(TypingState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.participants.map(\.participantId), ["supervisor-1", "flow"])
        XCTAssertEqual(decoded.participants.first?.audience, .internalParticipants)
        XCTAssertNil(decoded.participants.last?.userId)
        XCTAssertEqual(try JSONDecoder().decode(TypingState.self, from: JSONEncoder().encode(decoded)), decoded)
    }

    func testUnknownTypingRoleFailsClosed() {
        let json = #"{"participants":[{"participantId":"p1","role":"supervisor","audience":"all"}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(TypingState.self, from: Data(json.utf8)))
    }
}
