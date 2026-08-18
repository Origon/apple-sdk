import Foundation
import Combine
import OrigonSDK

/// Owns the `OrigonClient` for the lifetime of an authenticated session and
/// serves as the single entry point the UI uses for both call and chat
/// functionality.
///
/// The app has exactly one of these (injected at the root); every other
/// component that needs the SDK consumes it from here. Responsibilities:
///
/// - Hold the `OrigonClient` handle (one per logged-in session).
/// - Own the `CallService` and `ChatService` instances and expose them so
///   the UI can reach `sdk.call` / `sdk.chat`.
/// - Host the shared session list (used by both call and chat) and the
///   cache-first directory stream.
/// - Drain the SDK's event channel on a 50 ms timer and broadcast every
///   `ClientEvent` to subscribers via `events`. Consumers (e.g.
///   `CallService`) filter by `sessionId`.
/// - Tear down cleanly on logout — destroys the client and stops the
///   poll loop so the FFI handle is released.
@MainActor
final class SDKManager: ObservableObject {

    @Published private(set) var isReady = false
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var isLoadingSessions = false

    private(set) var client: OrigonClient?

    let call: CallService
    let chat: ChatService

    /// Broadcast every event drained from `client.pollEvent()`. Use a
    /// `PassthroughSubject` so subscribers see events without retaining
    /// any per-event state on this side.
    private let eventSubject = PassthroughSubject<ClientEvent, Never>()
    var events: AnyPublisher<ClientEvent, Never> { eventSubject.eraseToAnyPublisher() }

    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init() {
        self.call = CallService()
        self.chat = ChatService()
        // Bind child services to this manager so they can read `client` and
        // subscribe to `events`. Done after self-init so we can pass `self`.
        self.call.bind(to: self)
        self.chat.bind(to: self)

        // Re-publish child @Published changes through this manager so views
        // observing only SDKManager re-render when `chat.messages` or
        // `call.phase` change. SwiftUI does not chain ObservableObjects
        // automatically.
        self.call.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.chat.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// Connect to the Origon backend and start the event poll loop.
    func initialize(
        endpoint: String,
        userId: String? = nil,
        token: String? = nil
    ) async throws {
        // `userId` is optional; when nil the SDK resolves a device
        // identifier internally to use as the fallback.
        let config = ClientConfig(
            endpoint: endpoint,
            token: token,
            userId: userId
        )

        // OrigonClient(config:) blocks on the FFI runtime — do it off the
        // main thread so the UI stays responsive during the /config round
        // trip.
        let newClient = try await Task.detached {
            try OrigonClient(config: config)
        }.value

        self.client = newClient
        self.isReady = true
        startPolling()
    }

    /// Destroy the client, reset child services, and stop polling.
    /// Idempotent — safe to call on logout regardless of whether
    /// `initialize` ran.
    func teardown() {
        stopPolling()
        chat.destroy()
        sessions = []
        client?.close()
        client = nil
        isReady = false
    }

    // MARK: - Sessions (shared between call and chat)

    /// Refresh the cached session list from the SDK. Used by the sidebar
    /// (chat history) and any future call-history surface.
    func refreshSessions() async throws {
        guard let client else { return }
        isLoadingSessions = true
        do {
            for try await update in try client.sessionDirectoryUpdates() {
                switch update {
                case .snapshot(let snapshot):
                    sessions = snapshot.sessions
                case .refreshFailed(let error, _):
                    throw error
                }
            }
            isLoadingSessions = false
        } catch {
            isLoadingSessions = false
            throw error
        }
    }

    // MARK: - Event polling

    private func startPolling() {
        stopPolling()
        // 50 ms cadence matches the web client's poll loop. Drains up to
        // 50 events per tick to avoid backlog if a burst arrives between
        // ticks.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drainEvents()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func drainEvents() {
        guard let client else { return }
        for _ in 0..<50 {
            guard let event = client.pollEvent() else { break }
            eventSubject.send(event)
        }
    }
}
