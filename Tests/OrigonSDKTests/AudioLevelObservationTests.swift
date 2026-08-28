import Foundation
import XCTest
@testable import OrigonSDK

private final class FakeAudioLevelSource: AudioLevelNativeSource, @unchecked Sendable {
    private let condition = NSCondition()
    private var steps: [AudioLevelNativeStep] = []
    private var cancelled = false
    private var freed = false
    var onFree: (@Sendable () -> Void)?

    func push(_ step: AudioLevelNativeStep) {
        condition.lock()
        steps.append(step)
        condition.signal()
        condition.unlock()
    }

    func next() -> AudioLevelNativeStep {
        condition.lock()
        while steps.isEmpty && !cancelled {
            condition.wait()
        }
        let step = cancelled ? .cancelled : steps.removeFirst()
        condition.unlock()
        return step
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }

    func free() {
        condition.lock()
        let notify = !freed
        freed = true
        condition.unlock()
        if notify { onFree?() }
    }
}

private final class ObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: AudioLevelObservation?

    func store(_ token: AudioLevelObservation) {
        lock.lock()
        self.token = token
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let token = token
        lock.unlock()
        token?.cancel()
    }
}

private final class CallbackCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        value += 1
        let current = value
        lock.unlock()
        return current
    }

    func load() -> Int {
        lock.lock()
        let current = value
        lock.unlock()
        return current
    }
}

final class AudioLevelObservationTests: XCTestCase {
    private let ordinary = SessionAudioLevels(
        sessionId: "voice-1",
        outbound: 0.5,
        inbound: 0.25,
        endpoints: [EndpointAudioLevel(endpointId: "endpoint-1", inbound: 0.125)]
    )
    private let terminalZero = SessionAudioLevels(
        sessionId: "voice-1",
        outbound: 0,
        inbound: 0,
        endpoints: [EndpointAudioLevel(endpointId: "endpoint-1", inbound: 0)]
    )

    private func client(
        source: FakeAudioLevelSource,
        onDestroy: @escaping @Sendable () -> Void = {}
    ) throws -> OrigonClient {
        let handle = try XCTUnwrap(OpaquePointer(bitPattern: 1))
        return OrigonClient(
            testingHandle: handle,
            subscribeAudioLevels: { _, _ in source },
            destroy: { _ in onDestroy() }
        )
    }

    func testCancelReentrantlyFromOrdinaryCallbackHasNoDeadlockOrLateCallback() throws {
        let source = FakeAudioLevelSource()
        let freed = expectation(description: "native observation freed off-main")
        source.onFree = { freed.fulfill() }
        let client = try client(source: source)
        let box = ObservationBox()
        let count = CallbackCount()
        let delivered = expectation(description: "ordinary callback")
        let token = try client.observeAudioLevels(sessionId: "voice-1") { _ in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(count.increment(), 1)
            box.cancel()
            delivered.fulfill()
        }
        box.store(token)
        source.push(.update(ordinary))
        source.push(.update(ordinary))
        wait(for: [delivered, freed], timeout: 2)
        XCTAssertEqual(count.load(), 1)
    }

    func testCloseReentrantlyFromOrdinaryCallbackHasNoDeadlockOrLateCallback() throws {
        let source = FakeAudioLevelSource()
        let freed = expectation(description: "native observation freed off-main")
        let destroyed = expectation(description: "client destroyed")
        source.onFree = { freed.fulfill() }
        let client = try client(source: source) { destroyed.fulfill() }
        let count = CallbackCount()
        let delivered = expectation(description: "ordinary callback")
        let token = try client.observeAudioLevels(sessionId: "voice-1") { _ in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(count.increment(), 1)
            client.close()
            delivered.fulfill()
        }
        withExtendedLifetime(token) {
            source.push(.update(ordinary))
            source.push(.update(ordinary))
            wait(for: [delivered, destroyed, freed], timeout: 2)
        }
        XCTAssertEqual(count.load(), 1)
    }

    func testCancelReentrantlyFromTerminalZeroCallbackHasNoDeadlock() throws {
        let source = FakeAudioLevelSource()
        let freed = expectation(description: "native observation freed off-main")
        source.onFree = { freed.fulfill() }
        let client = try client(source: source)
        let box = ObservationBox()
        let delivered = expectation(description: "terminal zero callback")
        let token = try client.observeAudioLevels(sessionId: "voice-1") { levels in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(levels.outbound, 0)
            XCTAssertEqual(levels.inbound, 0)
            XCTAssertEqual(levels.endpoints.first?.inbound, 0)
            box.cancel()
            delivered.fulfill()
        }
        box.store(token)
        source.push(.update(terminalZero))
        source.push(.end)
        wait(for: [delivered, freed], timeout: 2)
    }

    func testCloseReentrantlyFromTerminalZeroCallbackHasNoDeadlock() throws {
        let source = FakeAudioLevelSource()
        let freed = expectation(description: "native observation freed off-main")
        let destroyed = expectation(description: "client destroyed")
        source.onFree = { freed.fulfill() }
        let client = try client(source: source) { destroyed.fulfill() }
        let delivered = expectation(description: "terminal zero callback")
        let token = try client.observeAudioLevels(sessionId: "voice-1") { levels in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(levels.outbound, 0)
            XCTAssertEqual(levels.inbound, 0)
            client.close()
            delivered.fulfill()
        }
        withExtendedLifetime(token) {
            source.push(.update(terminalZero))
            source.push(.end)
            wait(for: [delivered, destroyed, freed], timeout: 2)
        }
    }
}
