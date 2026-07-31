import SwiftUI
import Combine
import OrigonSDK

/// Owns in-memory chat state for every active chat session.
///
/// Multi-active by design: each open chat session keeps its own
/// `SessionUIState` (messages, typing flag, pending uploads) in
/// `sessionsState`. The `messages`, `isTyping`, and `pendingAttachments`
/// accessors project the focused session (`currentSessionId`) so the
/// existing view bindings keep working.
///
/// Lifecycle:
/// - `openSession(id:)` focuses an existing session if we already hold
///   state for it, otherwise fetches history + opens the SDK chat
///   channel and stores fresh state.
/// - `openSession(id: nil)` switches focus to the "new session" empty
///   state. Other open sessions stay alive in the background.
/// - `sendMessage(text:)` lazily opens an SDK chat session on the very
///   first send when there is none, then dispatches to
///   `client.sendMessage`. The SDK auto-fires `messageAdded(provisional)`
///   and `messageUpdated(delivered/failed)`; the event handler is what
///   populates `messages`.
/// - `uploadFile(...)` drives the upload straight through the SDK with
///   live `onProgress` updates. The write lane is widget-scoped, so no
///   session is opened for it — an attachment can be the first thing a
///   visitor sends. Attachments persist as `PendingAttachment` rows
///   until either bundled into a `sendMessage` or removed by the user
///   (which also deletes the server-side blob).
/// - `endCurrentSession()` ends the focused SDK session and drops its
///   UI state. Background sessions are unaffected.
@MainActor
final class ChatService: ObservableObject {

    struct SessionUIState: Equatable {
        var messages: [Message] = []
        var isTyping: Bool = false
        /// Composer-tile state for this session. Survives session
        /// switches so an upload kicked off in session A doesn't vanish
        /// when the user peeks at session B.
        var pendingAttachments: [PendingAttachment] = []
    }

    @Published private(set) var sessionsState: [String: SessionUIState] = [:]
    @Published private(set) var currentSessionId: String?
    @Published var error: String?

    /// Pending uploads queued before any chat session exists. Uploads no
    /// longer wait on a session, so this list is drained by whichever
    /// comes first: `ensureChatSession` (the lazy start on the first
    /// send) or `adoptDrafts(into:)` (the user focusing an existing
    /// session). Both move the rows into that session's
    /// `pendingAttachments`.
    @Published private(set) var draftPendingAttachments: [PendingAttachment] = []

    private weak var sdk: SDKManager?
    private var cancellables = Set<AnyCancellable>()

    /// In-flight lazy session-start. Racing callers (e.g. the user taps
    /// send twice with no session yet) all `await` this single task so
    /// only one `POST /session/start` fires and the draft → session
    /// migration happens exactly once.
    private var sessionStartTask: Task<String, Error>?

    /// SDKManager creates this and calls `bind(to:)` once it can pass `self`.
    /// Subscribes to the manager's event stream so messages and typing
    /// updates land in `sessionsState` for every open chat session.
    func bind(to manager: SDKManager) {
        self.sdk = manager
        manager.events
            .sink { [weak self] event in self?.handleEvent(event) }
            .store(in: &cancellables)
    }

    // MARK: - Focused-session accessors

    /// Messages for the currently focused session. The UI binds here.
    var messages: [Message] {
        guard let id = currentSessionId else { return [] }
        return sessionsState[id]?.messages ?? []
    }

    /// Whether the peer is typing in the focused session.
    var isTyping: Bool {
        guard let id = currentSessionId else { return false }
        return sessionsState[id]?.isTyping ?? false
    }

    /// Composer-tile list for the focused session, or the draft list
    /// when no session is open yet.
    var pendingAttachments: [PendingAttachment] {
        if let id = currentSessionId {
            return sessionsState[id]?.pendingAttachments ?? []
        }
        return draftPendingAttachments
    }

    var attachmentsAllowed: Bool {
        guard let client = sdk?.client else { return false }
        let p = client.attachmentPolicy
        return p.images.enabled || p.documents.enabled
            || p.videos.enabled || p.audio.enabled
    }

    var hasUploadingAttachments: Bool {
        pendingAttachments.contains { $0.status == .uploading }
    }

    // MARK: - Session lifecycle

    /// Focus a chat session.
    ///
    /// - Parameter id: `nil` switches to the "new session" empty state
    ///   without touching any open sessions. A non-nil id either focuses
    ///   existing in-memory state, or fetches history + opens the SDK
    ///   chat channel for that id (and refreshes the sidebar list so the
    ///   newly-active session is visible there).
    func openSession(id: String?) async {
        guard let id else {
            currentSessionId = nil
            return
        }
        if sessionsState[id] != nil {
            currentSessionId = id
            adoptDrafts(into: id)
            return
        }
        guard let client = sdk?.client else { return }
        do {
            // View-only open: fetch the history and render it, but do NOT
            // call `startChat` — that verb exists to open a session WITH the
            // visitor's first message, and opening one here just to read a
            // past conversation would attach a participant and start a chat
            // nobody has spoken in. The session goes live on the first send.
            let history = try await Task.detached {
                try client.getSession(id: id)
            }.value
            sessionsState[id] = SessionUIState(messages: history.history)
            currentSessionId = id
            adoptDrafts(into: id)
            // Refresh sidebar so the now-open session shows up.
            try? await sdk?.getSessions()
        } catch {
            self.error = "Failed to open session: \(error.localizedDescription)"
        }
    }

    /// Move any draft tiles onto the session being focused.
    ///
    /// The draft list holds rows picked while nothing was open. Uploads no
    /// longer wait on a session, so nothing drains that list on its own any
    /// more — and the `pendingAttachments` accessor stops reading it the
    /// moment a real session is focused. Left alone, a tile picked before
    /// opening a conversation would vanish from the composer (unremovable,
    /// its blob stranded on the server) and then silently reappear on
    /// whichever session happened to be started next. Adopting it here keeps
    /// it visible and removable in the chat the user is actually looking at.
    private func adoptDrafts(into id: String) {
        guard !draftPendingAttachments.isEmpty else { return }
        sessionsState[id]?.pendingAttachments.append(contentsOf: draftPendingAttachments)
        draftPendingAttachments = []
    }

    /// Send a text message + any completed attachments.
    ///
    /// With a session already focused this is a plain `sendMessage`. With
    /// none, the send IS the open: `startChat` carries the visitor's first
    /// message, so there is no window where a session exists but has said
    /// nothing (the server gates the flow on visitor content and reaps a
    /// silent session — see `StartChatOptions`).
    ///
    /// Does not mutate `messages` directly — the SDK fires
    /// `messageAdded(provisional)` and `messageUpdated(delivered/failed)`
    /// for every send, so `handleEvent` is the single source of UI
    /// updates.
    func sendMessage(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Read tiles through the accessor: with no session focused they are
        // still on the draft list, and an attachment-only first message is
        // valid.
        let completed = pendingAttachments
            .compactMap { $0.status == .completed ? $0.attachment : nil }
        guard !trimmed.isEmpty || !completed.isEmpty else { return }
        guard let client = sdk?.client else { return }

        let payload = SendMessagePayload(
            text: trimmed.isEmpty ? nil : trimmed,
            attachments: completed
        )
        do {
            let id: String
            if let existing = currentSessionId {
                id = existing
                _ = try await Task.detached {
                    try client.sendMessage(id: existing, payload: payload)
                }.value
            } else {
                id = try await openAndSend(payload: payload)
            }

            // Completed attachments are now owned by the sent message;
            // any rows still in `.uploading` / `.error` are left alone
            // (the user picked them too late or they failed — they keep
            // their tile).
            sessionsState[id]?.pendingAttachments.removeAll { $0.status == .completed }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Notify the peer that the user is typing on the focused session.
    /// Cheap to call from `onChange`; the SDK debounces wire traffic.
    func notifyTyping() {
        guard let client = sdk?.client, let id = currentSessionId else { return }
        try? client.notifyTyping(id: id)
    }

    /// Force outbound typing off — input went empty. The SDK also fires
    /// this implicitly on send and on endSession.
    func stopTyping() {
        guard let client = sdk?.client, let id = currentSessionId else { return }
        try? client.stopTyping(id: id)
    }

    /// End the focused SDK chat session and drop its UI state. Other
    /// open sessions are untouched.
    func endCurrentSession() {
        guard let id = currentSessionId else { return }
        if let client = sdk?.client {
            try? client.endSession(id)
        }
        sessionsState[id] = nil
        currentSessionId = nil
    }

    // MARK: - Attachments

    /// Queue a file upload onto the focused session (or the draft list
    /// when no session is open yet). The tile appears immediately at
    /// `progress = 0`; live progress updates land via `onProgress`.
    /// On success the row flips to `.completed` and carries the
    /// server-issued ``Attachment``; on failure to `.error` with a
    /// human-friendly message keyed off ``OrigonError`` codes.
    func uploadFile(data: Data, fileName: String, contentType: String, previewImage: UIImage?) {
        let localId = UUID().uuidString
        let pending = PendingAttachment(
            id: localId,
            fileName: fileName,
            contentType: contentType,
            previewImage: previewImage,
            status: .uploading,
            progress: 0,
            attachment: nil,
            errorText: nil
        )
        appendPending(pending)
        Task { await runUpload(localId: localId, data: data, fileName: fileName) }
    }

    func removePendingAttachment(id: String) {
        // Snapshot the row before we mutate so we can fire the right
        // server-side cleanup. We search both the draft list and every
        // session's pending list — the row may have started life in
        // the draft and migrated into a session.
        var removed: PendingAttachment?
        if let i = draftPendingAttachments.firstIndex(where: { $0.id == id }) {
            removed = draftPendingAttachments[i]
            draftPendingAttachments.remove(at: i)
        } else {
            for (sid, state) in sessionsState {
                if let i = state.pendingAttachments.firstIndex(where: { $0.id == id }) {
                    var s = state
                    removed = s.pendingAttachments.remove(at: i)
                    sessionsState[sid] = s
                    break
                }
            }
        }
        guard let removed, let client = sdk?.client else { return }

        switch removed.status {
        case .uploading:
            // The SDK's deleteAttachment is dual-purpose: it matches
            // our local id against its in-flight upload table and
            // tears down the QUIC stream with a RESET. The upload's
            // awaiter throws `.cancelled`, which `runUpload` swallows.
            // Fires regardless of which list hosted the row — the write
            // lane is widget-scoped, and a draft-list upload is now the
            // common case since uploads no longer wait on a session.
            Task.detached {
                try? await client.deleteAttachment(attachmentId: id)
            }

        case .completed:
            // Server already has the blob; clean it up with its
            // server-issued id.
            guard let serverId = removed.attachment?.id else { return }
            Task.detached {
                try? await client.deleteAttachment(attachmentId: serverId)
            }

        case .error:
            // Nothing committed to the server — local remove is enough.
            return
        }
    }

    // MARK: - Teardown

    /// End every active SDK chat session and clear UI state. Called on
    /// logout via `SDKManager.teardown`.
    func destroy() {
        if let client = sdk?.client {
            for id in sessionsState.keys {
                try? client.endSession(id)
            }
        }
        sessionsState = [:]
        currentSessionId = nil
        draftPendingAttachments = []
        sessionStartTask = nil
        error = nil
    }

    // MARK: - Event handling

    private func handleEvent(_ event: ClientEvent) {
        let sid = event.sessionId

        // `sessionUpdated` may arrive for an id we don't hold state for
        // yet (rare server-side remap path) — handle it before the guard
        // so we don't drop it.
        if case let .sessionUpdated(_, newSessionId) = event,
           let state = sessionsState[sid]
        {
            sessionsState[newSessionId] = state
            sessionsState[sid] = nil
            if currentSessionId == sid { currentSessionId = newSessionId }
            return
        }

        // Filter everything else by sessions we own. Voice events for
        // `CallService` get dropped here naturally — their session ids
        // never enter `sessionsState`.
        guard sessionsState[sid] != nil else { return }

        switch event {
        case .messageAdded(_, let msg):
            sessionsState[sid]?.messages.append(msg)

        case .messageUpdated(_, let key, let msg):
            updateMessage(in: sid, key: key, message: msg)

        case .typing(_, let isTyping):
            sessionsState[sid]?.isTyping = isTyping

        case .disconnected(_, let reason):
            // Local close path is the one we initiated via
            // `endCurrentSession` / `destroy`; UI state is already gone.
            // For server / network closes, drop state so the next
            // `openSession` refetches and reopens cleanly.
            if reason != .localClose {
                if sid == currentSessionId {
                    error = "Chat disconnected"
                }
                sessionsState[sid] = nil
                if currentSessionId == sid { currentSessionId = nil }
            }

        case .chatSessionEnded:
            // Clean end — the agent or flow closed the chat. State is
            // deliberately KEPT so the user stays on the transcript, and
            // there is no error toast: this is not a failure. A production
            // app would also flip the composer read-only and show an
            // "ended" divider; that is UI work this example leaves out.
            break

        case .sessionUpdated, .connected, .reconnecting, .reconnected,
             .controlUpdated, .peerAttached, .peerDetached, .callError,
             .audioRouteChanged:
            break
        }
    }

    private func updateMessage(in sid: String, key: String, message: Message) {
        guard var state = sessionsState[sid] else { return }
        if let idx = state.messages.firstIndex(where: { messageKey($0) == key }) {
            state.messages[idx] = message
        } else {
            // Defensive: an update can't find a prior add (e.g. race or
            // duplicate). Append so the row still appears.
            state.messages.append(message)
        }
        sessionsState[sid] = state
    }

    // Outbound rows show up first as `messageAdded` with `localId` set
    // and `id == ""`; the server `id` lands on `messageUpdated`. Prefer
    // `localId` so the same row tracks across the sending → delivered
    // transition. Inbound rows have no `localId`, so `id` wins.
    private func messageKey(_ m: Message) -> String {
        if let local = m.localId, !local.isEmpty { return local }
        return m.id
    }

    // MARK: - Upload internals

    /// Open a chat session by SENDING — `startChat` carries `payload` as the
    /// visitor's first message and returns the new session id.
    ///
    /// This is the only path that opens a chat. Uploads are widget-scoped
    /// and never open one, and the sidebar's `openSession` is view-only.
    ///
    /// A second send arriving while a start is in flight joins that start
    /// and then sends normally — it must NOT start its own session, and it
    /// can't join by payload either, since the first message is already
    /// spoken for.
    private func openAndSend(payload: SendMessagePayload) async throws -> String {
        guard let client = sdk?.client else { throw OrigonError.notInitialized }

        if let inFlight = sessionStartTask {
            let id = try await inFlight.value
            _ = try await Task.detached {
                try client.sendMessage(id: id, payload: payload)
            }.value
            return id
        }

        let task = Task<String, Error> { [weak self] in
            do {
                // `startChat` returns the session id BEFORE the message goes
                // out, and a first message that fails to DELIVER does not
                // throw — it arrives as `messageUpdated(.failed)` so the user
                // can retry. Only a terminal refusal throws.
                let response = try await Task.detached {
                    try client.startChat(StartChatOptions(firstMessage: payload))
                }.value
                await MainActor.run {
                    guard let self else { return }
                    var state = self.sessionsState[response.sessionId] ?? SessionUIState()
                    // Merge any draft tiles that were queued while the
                    // start was in flight. Sessions opened concurrently
                    // via `openSession` would already be in
                    // `sessionsState`; preserve their existing pending
                    // list and append the draft entries onto it.
                    state.pendingAttachments.append(contentsOf: self.draftPendingAttachments)
                    self.sessionsState[response.sessionId] = state
                    self.draftPendingAttachments = []
                    // Only steal focus if the user didn't navigate to a
                    // different session while the start was in flight.
                    if self.currentSessionId == nil {
                        self.currentSessionId = response.sessionId
                    }
                    self.sessionStartTask = nil
                }
                try? await self?.sdk?.getSessions()
                return response.sessionId
            } catch {
                // Clear the cached task on failure so the next caller
                // retries instead of inheriting our error.
                await MainActor.run { self?.sessionStartTask = nil }
                throw error
            }
        }
        sessionStartTask = task
        return try await task.value
    }

    private func runUpload(localId: String, data: Data, fileName: String) async {
        guard let client = sdk?.client else {
            updatePending(localId: localId) {
                $0.status = .error
                $0.errorText = "Client not ready"
            }
            return
        }
        // `uploadFile` appends the row and then ENQUEUES this task, so an ×
        // tap can run in between. If the row is gone by the time we get
        // here, abort before any wire work starts — the cancel it fired
        // landed before the SDK registered its in-flight entry, so it would
        // have degraded to a DELETE of an id the server never saw, leaving
        // an orphan blob behind this upload.
        guard pendingExists(localId: localId) else { return }

        do {
            let attachment = try await client.uploadAttachment(
                uploadId: localId,
                data: data,
                fileName: fileName,
                onProgress: { [weak self] progress in
                    self?.updatePending(localId: localId) { row in
                        if let pct = progress.percent {
                            row.progress = Double(pct)
                        } else if let total = progress.totalBytes, total > 0 {
                            row.progress = Double(progress.bytesUploaded) / Double(total) * 100
                        }
                    }
                }
            )
            updatePending(localId: localId) {
                $0.status = .completed
                $0.progress = 100
                $0.attachment = attachment
            }
        } catch let err as OrigonError where err.kind == .cancelled {
            // The row was removed by `removePendingAttachment` and the
            // cancel signal raced through the SDK; nothing left to do.
            // (`updatePending` would silently no-op anyway since the
            // row is gone, but the explicit branch documents intent.)
            return
        } catch {
            // Surface whatever the SDK gave us. `OrigonError.message`
            // is always populated by the Rust side per the contract;
            // foreign errors fall back to `localizedDescription`.
            let message: String
            if let err = error as? OrigonError {
                message = err.message ?? err.code ?? "Upload failed"
            } else {
                message = error.localizedDescription
            }
            updatePending(localId: localId) {
                $0.status = .error
                $0.errorText = message
            }
            // Mirror onto the published `error` so the view can toast
            // it. The tile's inline error overlay is the persistent
            // indicator; the toast is the at-the-moment cue.
            self.error = message
        }
    }

    /// True when a pending row with the given local id is still hosted
    /// somewhere — draft list or any session. Used by `runUpload` as a
    /// pre-upload existence check; see the call site for the no-session
    /// cancel race it plugs.
    private func pendingExists(localId: String) -> Bool {
        if draftPendingAttachments.contains(where: { $0.id == localId }) {
            return true
        }
        for state in sessionsState.values {
            if state.pendingAttachments.contains(where: { $0.id == localId }) {
                return true
            }
        }
        return false
    }

    /// Append a pending row onto whichever list is appropriate right
    /// now. When no session is open we push into the draft list;
    /// `ensureChatSession` migrates it into the session's pending list
    /// when the start resolves.
    private func appendPending(_ row: PendingAttachment) {
        if let id = currentSessionId {
            var state = sessionsState[id] ?? SessionUIState()
            state.pendingAttachments.append(row)
            sessionsState[id] = state
        } else {
            draftPendingAttachments.append(row)
        }
    }

    /// Locate a pending row by its local id and apply `mutate`. Searches
    /// the draft list first, then every session's pending list — the
    /// row may have moved across the draft → session boundary mid-
    /// upload, and the caller (a progress callback) has no way of
    /// knowing that. Silently drops the update when the row is gone,
    /// e.g. the user removed the tile after it completed.
    private func updatePending(
        localId: String,
        _ mutate: (inout PendingAttachment) -> Void
    ) {
        if let i = draftPendingAttachments.firstIndex(where: { $0.id == localId }) {
            mutate(&draftPendingAttachments[i])
            return
        }
        for (sid, state) in sessionsState {
            if let i = state.pendingAttachments.firstIndex(where: { $0.id == localId }) {
                var s = state
                mutate(&s.pendingAttachments[i])
                sessionsState[sid] = s
                return
            }
        }
    }

}
