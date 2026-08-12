import Foundation
import XCTest
@testable import OrigonSDK

final class MobileContinuityTests: XCTestCase {
    func testSessionSummaryRequiresActive() throws {
        let complete = #"{"sessionId":"s","subject":"x","channel":"chat","active":true,"createdAt":"c","updatedAt":"u"}"#
        XCTAssertTrue(try JSONDecoder().decode(SessionSummary.self, from: Data(complete.utf8)).active)

        let legacy = #"{"sessionId":"s","subject":"x","channel":"chat","createdAt":"c","updatedAt":"u"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(SessionSummary.self, from: Data(legacy.utf8)))
    }

    func testNotificationGenerationMustMatchExactly() throws {
        let suiteName = "ai.origon.sdk.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("current", forKey: PushRegistrationStore.generationKey)

        XCTAssertTrue(OrigonPushNotification.isCurrent(
            userInfo: ["endpointGeneration": "current"],
            appGroupIdentifier: suiteName
        ))
        XCTAssertFalse(OrigonPushNotification.isCurrent(
            userInfo: ["endpointGeneration": "stale"],
            appGroupIdentifier: suiteName
        ))
        XCTAssertFalse(OrigonPushNotification.isCurrent(userInfo: [:], appGroupIdentifier: suiteName))
    }

    func testExactGenerationCopiesAuthorizedTitleAndPreview() {
        let copy = OrigonPushNotification.deliveryCopy(
            providerTitle: "Provider title",
            providerBody: "Provider body",
            userInfo: [
                "endpointGeneration": "current",
                "title": "Agent Name",
                "preview": "Authorized preview",
            ],
            currentGeneration: "current"
        )

        XCTAssertEqual(copy.title, "Agent Name")
        XCTAssertEqual(copy.body, "Authorized preview")
    }

    func testStaleGenerationPreservesProviderVisibleCopy() {
        let copy = OrigonPushNotification.deliveryCopy(
            providerTitle: "Provider title",
            providerBody: "Provider body",
            userInfo: [
                "endpointGeneration": "stale",
                "title": "Unauthorized title",
                "preview": "Unauthorized preview",
            ],
            currentGeneration: "current"
        )

        XCTAssertEqual(copy.title, "Provider title")
        XCTAssertEqual(copy.body, "Provider body")
    }

    func testMissingGenerationPreservesProviderVisibleCopy() {
        let copy = OrigonPushNotification.deliveryCopy(
            providerTitle: "Provider title",
            providerBody: "Provider body",
            userInfo: [
                "title": "Unauthorized title",
                "preview": "Unauthorized preview",
            ],
            currentGeneration: "current"
        )

        XCTAssertEqual(copy.title, "Provider title")
        XCTAssertEqual(copy.body, "Provider body")
    }

    func testBlankAuthorizedTitlePreservesProviderTitle() {
        let copy = OrigonPushNotification.deliveryCopy(
            providerTitle: "Provider title",
            providerBody: "Provider body",
            userInfo: [
                "endpointGeneration": "current",
                "title": " \n\t ",
                "preview": "Authorized preview",
            ],
            currentGeneration: "current"
        )

        XCTAssertEqual(copy.title, "Provider title")
        XCTAssertEqual(copy.body, "Authorized preview")
    }

    func testAbsentAuthorizedTitlePreservesProviderTitle() {
        let copy = OrigonPushNotification.deliveryCopy(
            providerTitle: "Provider title",
            providerBody: "Provider body",
            userInfo: [
                "endpointGeneration": "current",
                "preview": "Authorized preview",
            ],
            currentGeneration: "current"
        )

        XCTAssertEqual(copy.title, "Provider title")
        XCTAssertEqual(copy.body, "Authorized preview")
    }
}
