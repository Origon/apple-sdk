import Foundation
import COrigonSDK

/// The primary interface to the Origon platform on Apple platforms.
///
/// Backed by the `COrigonSDK` XCFramework (statically linked
/// `libsession.a`). One instance owns one native handle and one tokio
/// runtime; create at app start, deinit when shutting down.
///
/// All fallible methods throw ``OrigonError`` with a structured
/// `kind` / `statusCode` / `code` / `message`.
public final class OrigonClient: @unchecked Sendable {
    private var handle: OpaquePointer?

    /// Install the global tracing subscriber. Idempotent — only the
    /// first call installs; subsequent calls are no-ops.
    ///
    /// `filter` accepts `RUST_LOG`-style directives. Pass `nil` for the
    /// SDK default.
    public static func initLogging(filter: String? = nil) {
        if let filter {
            filter.withCString { cstr in _ = session_init_logging(cstr) }
        } else {
            _ = session_init_logging(nil)
        }
    }

    public init(config: ClientConfig) throws {
        var err = SessionError()
        var newHandle: OpaquePointer?
        let attributesJson = try Self.encodeAttributes(config.attributes)
        let bundleId = Bundle.main.bundleIdentifier
        let rc: Int32 = config.endpoint.withCString { endpointPtr in
            withOptionalCString(bundleId) { bundlePtr in
                withOptionalCString(config.token) { tokenPtr in
                    withOptionalCString(config.userId) { userIdPtr in
                        withOptionalCString(attributesJson) { attrsPtr in
                            var cfg = SessionClientConfig(
                                endpoint: endpointPtr,
                                bundle_id: bundlePtr,
                                token: tokenPtr,
                                user_id: userIdPtr,
                                platform: config.platform.toC(),
                                attributes_json: attrsPtr
                            )
                            return session_client_create(&cfg, &newHandle, &err)
                        }
                    }
                }
            }
        }
        guard rc == 0, let newHandle else {
            throw OrigonError.consume(&err)
        }
        self.handle = newHandle
    }

    /// Serialize a `[String: Any]?` to a JSON string. Returns `nil` when
    /// the input is `nil`. Throws `OrigonError(.other, ...)` if the
    /// dictionary contains a value `JSONSerialization` can't handle.
    private static func encodeAttributes(_ attrs: [String: Any]?) throws -> String? {
        guard let attrs else { return nil }
        do {
            let data = try JSONSerialization.data(withJSONObject: attrs, options: [])
            guard let s = String(data: data, encoding: .utf8) else {
                throw OrigonError(kind: .other, message: "attributes encode: utf8")
            }
            return s
        } catch let e as OrigonError {
            throw e
        } catch {
            throw OrigonError(
                kind: .other,
                message: "attributes encode: \(error.localizedDescription)"
            )
        }
    }

    deinit {
        if let handle {
            session_client_destroy(handle)
        }
    }

    // MARK: - Cached /config getters

    /// Pre-populated first assistant message configured for the tenant.
    public var startMessage: String {
        guard let handle else { return "" }
        guard let cstr = session_client_get_start_message(handle) else { return "" }
        defer { session_string_free(cstr) }
        return String(cString: cstr)
    }

    public var isChatEnabled: Bool {
        guard let handle else { return false }
        return session_client_is_chat_enabled(handle) == 1
    }

    public var isCallEnabled: Bool {
        guard let handle else { return false }
        return session_client_is_call_enabled(handle) == 1
    }

    /// True when chat and voice may share one session.
    public var multipleChannels: Bool {
        guard let handle else { return false }
        return session_client_is_multiple_channels_allowed(handle) == 1
    }

    public var attachmentPolicy: AttachmentPolicy {
        guard let handle else { return .disabled }
        var raw = SessionAttachmentPolicy()
        guard session_client_get_attachment_policy(handle, &raw) == 0 else {
            return .disabled
        }
        return AttachmentPolicy(
            images: AttachmentRule(enabled: raw.images.enabled == 1, maxSize: raw.images.max_size),
            documents: AttachmentRule(enabled: raw.documents.enabled == 1, maxSize: raw.documents.max_size),
            videos: AttachmentRule(enabled: raw.videos.enabled == 1, maxSize: raw.videos.max_size),
            audio: AttachmentRule(enabled: raw.audio.enabled == 1, maxSize: raw.audio.max_size)
        )
    }

    public var serverConfig: ServerConfig {
        ServerConfig(
            startMessage: startMessage,
            multipleChannels: multipleChannels,
            isChatEnabled: isChatEnabled,
            isCallEnabled: isCallEnabled,
            attachmentPolicy: attachmentPolicy
        )
    }

    /// Replace session-level attributes injected as `data.attributes`
    /// on subsequent `startSession` calls. Pass `nil` to clear.
    public func setAttributes(_ attrs: [String: Any]?) throws {
        guard let handle else { throw OrigonError.notInitialized }
        let json = try Self.encodeAttributes(attrs)
        var err = SessionError()
        let rc: Int32 = withOptionalCString(json) { ptr in
            session_client_set_attributes(handle, ptr, &err)
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    // MARK: - Session lifecycle

    public func startSession(_ options: StartSessionOptions) throws -> StartSessionResponse {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        var resp = SessionStartResponse()

        let rc: Int32 = withOptionalCString(options.sessionId) { sidPtr in
            withOptionalCString(options.data) { dataPtr in
                var opts = SessionStartOptions(
                    channel: options.channel.toC(),
                    session_id: sidPtr,
                    data_json: dataPtr
                )
                return session_client_start_session(handle, &opts, &resp, &err)
            }
        }

        guard rc == 0 else { throw OrigonError.consume(&err) }
        defer { session_start_response_free(&resp) }

        guard let sid = resp.session_id, let url = resp.url, let token = resp.token else {
            throw OrigonError(
                kind: .other,
                message: "incomplete StartSessionResponse"
            )
        }
        return StartSessionResponse(
            sessionId: String(cString: sid),
            url: String(cString: url),
            token: String(cString: token)
        )
    }

    /// Attach to a session whose ``StartSessionResponse`` was obtained
    /// out of band (multi-device handoff, deeplink, persisted session).
    public func joinSession(_ input: JoinSessionInput) throws {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        let rc: Int32 = input.sessionId.withCString { sidPtr in
            input.url.withCString { urlPtr in
                input.token.withCString { tokPtr in
                    var raw = SessionJoinSessionInput(
                        channel: input.channel.toC(),
                        session_id: sidPtr,
                        url: urlPtr,
                        token: tokPtr
                    )
                    return session_client_join_session(handle, &raw, &err)
                }
            }
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    public func endSession(_ id: String) throws {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        let rc = id.withCString { session_client_end_session(handle, $0, &err) }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    public func endAllSessions() throws {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        let rc = session_client_end_all_sessions(handle, &err)
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    /// `GET /sessions` — prior sessions for the configured `userId`.
    public func getSessions() throws -> [SessionSummary] {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        var jsonPtr: UnsafeMutablePointer<CChar>?
        let rc = session_client_get_sessions(handle, &jsonPtr, &err)
        if rc != 0 { throw OrigonError.consume(&err) }
        guard let jsonPtr else { return [] }
        defer { session_string_free(jsonPtr) }
        let json = String(cString: jsonPtr)
        guard let data = json.data(using: .utf8) else { return [] }
        do {
            return try JSONDecoder().decode([SessionSummary].self, from: data)
        } catch {
            throw OrigonError(
                kind: .other,
                message: "decode getSessions: \(error.localizedDescription)"
            )
        }
    }

    /// `GET /session/<id>` — history for one session.
    public func getSession(id: String) throws -> SessionHistory {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        var jsonPtr: UnsafeMutablePointer<CChar>?
        let rc = id.withCString {
            session_client_get_session(handle, $0, &jsonPtr, &err)
        }
        if rc != 0 { throw OrigonError.consume(&err) }
        guard let jsonPtr else { return SessionHistory(history: []) }
        defer { session_string_free(jsonPtr) }
        let json = String(cString: jsonPtr)
        guard let data = json.data(using: .utf8) else {
            return SessionHistory(history: [])
        }
        do {
            return try JSONDecoder().decode(SessionHistory.self, from: data)
        } catch {
            throw OrigonError(
                kind: .other,
                message: "decode getSession: \(error.localizedDescription)"
            )
        }
    }

    /// Snapshot of every active session.
    public func activeSessions() throws -> [ActiveSession] {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        var jsonPtr: UnsafeMutablePointer<CChar>?
        let rc = session_client_active_session_ids(handle, &jsonPtr, &err)
        if rc != 0 { throw OrigonError.consume(&err) }
        guard let jsonPtr else { return [] }
        defer { session_string_free(jsonPtr) }
        let json = String(cString: jsonPtr)

        guard
            let data = json.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else {
            return []
        }
        return array.compactMap { dict in
            guard
                let id = dict["id"],
                let chRaw = dict["channel"],
                let channel = Channel.fromWire(chRaw)
            else { return nil }
            return ActiveSession(sessionId: id, channel: channel)
        }
    }

    // MARK: - Voice controls

    public func setMute(id: String, muted: Bool) throws {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        let rc = id.withCString {
            session_client_set_mute(handle, $0, muted ? 1 : 0, &err)
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    public func setMuteAll(muted: Bool) throws {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        let rc = session_client_set_mute_all(handle, muted ? 1 : 0, &err)
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    /// Returns the new hold state.
    public func toggleHold(id: String) throws -> Bool {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        var state: Int32 = 0
        let rc = id.withCString {
            session_client_toggle_hold(handle, $0, &state, &err)
        }
        if rc != 0 { throw OrigonError.consume(&err) }
        return state != 0
    }

    /// Send a DTMF digit. `digit` must be one of `0-9`, `*`, `#`,
    /// `A-D` per RFC 4733.
    public func sendDtmf(id: String, digit: Character, durationMs: UInt32) throws {
        guard let handle else { throw OrigonError.notInitialized }
        guard let ascii = digit.asciiValue else {
            throw OrigonError(kind: .other, message: "DTMF digit must be ASCII")
        }
        var err = SessionError()
        let rc = id.withCString {
            session_client_send_dtmf(handle, $0, CChar(bitPattern: ascii), durationMs, &err)
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    // MARK: - Chat

    /// Chat-only — send a text / HTML message on the named session.
    ///
    /// Requires an active chat session for `id` (call ``startSession``
    /// first). The SDK fires ``ClientEvent/messageAdded(sessionId:message:)``
    /// (provisional, `status == .sending`) before the wire round-trip
    /// and ``ClientEvent/messageUpdated(sessionId:id:message:)`` (delivered
    /// or failed) after — both surface on ``pollEvent``. Returns the
    /// server-issued `Message`.
    @discardableResult
    public func sendMessage(id: String, payload: SendMessagePayload) throws -> Message {
        guard let handle else { throw OrigonError.notInitialized }
        let payloadJson = try Self.encodePayload(payload)
        var err = SessionError()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc: Int32 = id.withCString { idPtr in
            payloadJson.withCString { jsonPtr in
                session_client_send_message(handle, idPtr, jsonPtr, &outJson, &err)
            }
        }
        if rc != 0 { throw OrigonError.consume(&err) }
        guard let outJson else {
            throw OrigonError(kind: .other, message: "send_message: missing response body")
        }
        defer { session_string_free(outJson) }
        let json = String(cString: outJson)
        guard let data = json.data(using: .utf8) else {
            throw OrigonError(kind: .other, message: "send_message: utf8 decode")
        }
        do {
            return try JSONDecoder().decode(Message.self, from: data)
        } catch {
            throw OrigonError(
                kind: .other,
                message: "send_message decode: \(error.localizedDescription)"
            )
        }
    }

    /// Chat-only — register a keystroke on the named session. Cheap to
    /// call from `editingChanged`; the SDK debounces outbound
    /// `<sessionUrl>/typing` POSTs so only one wire call fires per
    /// typing burst.
    public func notifyTyping(id: String) throws {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        let rc = id.withCString {
            session_client_notify_typing(handle, $0, &err)
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    /// Chat-only — force outbound typing state to "off" immediately,
    /// cancelling any in-flight debounce. UI fires this on empty-text
    /// transitions; the SDK also fires it implicitly on
    /// ``sendMessage`` and on ``endSession``.
    public func stopTyping(id: String) throws {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        let rc = id.withCString {
            session_client_stop_typing(handle, $0, &err)
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    // MARK: - Attachments

    /// Chat-only — stream a file at `path` to the named chat session
    /// and return the server-issued ``Attachment``.
    ///
    /// For security-scoped `URL`s from `UIDocumentPicker` use the
    /// `url:` overload; for in-memory `Data` use the `data:` overload.
    /// Pass `uploadId` (default: fresh UUID) and hand the same value to
    /// ``deleteAttachment(sessionId:attachmentId:)`` to cancel
    /// in-flight. `onProgress` is invoked on `@MainActor`.
    ///
    /// See `client-sdk/session/docs/contract.md#attachment-flow` for
    /// MIME detection, policy prechecks, and error code semantics.
    public func uploadAttachment(
        sessionId: String,
        uploadId: String = UUID().uuidString,
        path: String,
        fileName: String,
        onProgress: (@MainActor @Sendable (UploadProgress) -> Void)? = nil
    ) async throws -> Attachment {
        guard let handle else { throw OrigonError.notInitialized }

        // Retain the closure across the C boundary; released on every
        // exit path below.
        let boxPtr: UnsafeMutableRawPointer? = onProgress.map { closure in
            Unmanaged.passRetained(UploadProgressBox(closure: closure)).toOpaque()
        }

        let trampoline: SessionUploadProgressCallback? = onProgress == nil ? nil : { ctx, uploaded, total in
            guard let ctx else { return }
            let box = Unmanaged<UploadProgressBox>.fromOpaque(ctx).takeUnretainedValue()
            let totalBytes: UInt64? = total < 0 ? nil : UInt64(total)
            let percent: UInt8?
            if let t = totalBytes, t > 0 {
                let p = (uploaded * 100) / t
                percent = UInt8(min(p, 100))
            } else {
                percent = nil
            }
            let progress = UploadProgress(
                bytesUploaded: uploaded,
                totalBytes: totalBytes,
                percent: percent
            )
            Task { @MainActor in
                box.closure(progress)
            }
        }

        let handleRef = handle
        do {
            let attachment = try await Task.detached {
                try Self.invokeUploadAttachment(
                    handle: handleRef,
                    sessionId: sessionId,
                    uploadId: uploadId,
                    path: path,
                    fileName: fileName,
                    callback: trampoline,
                    ctx: boxPtr
                )
            }.value
            if let boxPtr {
                Unmanaged<UploadProgressBox>.fromOpaque(boxPtr).release()
            }
            return attachment
        } catch {
            if let boxPtr {
                Unmanaged<UploadProgressBox>.fromOpaque(boxPtr).release()
            }
            throw error
        }
    }

    /// Convenience overload that materialises in-memory `data` under
    /// `NSTemporaryDirectory()` and delegates to the path-based
    /// overload. Temp file is removed on every exit path.
    public func uploadAttachment(
        sessionId: String,
        uploadId: String = UUID().uuidString,
        data: Data,
        fileName: String,
        onProgress: (@MainActor @Sendable (UploadProgress) -> Void)? = nil
    ) async throws -> Attachment {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        // Preserve extension so MIME sniff's filename fallback still works.
        let ext = (fileName as NSString).pathExtension
        let unique = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
        let tempURL = tempDir.appendingPathComponent(unique)
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try await uploadAttachment(
            sessionId: sessionId,
            uploadId: uploadId,
            path: tempURL.path,
            fileName: fileName,
            onProgress: onProgress
        )
    }

    /// Convenience overload for `URL`s. Manages
    /// `startAccessingSecurityScopedResource()` automatically for
    /// `UIDocumentPicker`-style URLs.
    public func uploadAttachment(
        sessionId: String,
        uploadId: String = UUID().uuidString,
        url: URL,
        fileName: String? = nil,
        onProgress: (@MainActor @Sendable (UploadProgress) -> Void)? = nil
    ) async throws -> Attachment {
        let needsScoped = url.startAccessingSecurityScopedResource()
        defer {
            if needsScoped { url.stopAccessingSecurityScopedResource() }
        }
        let resolvedName = fileName ?? url.lastPathComponent
        return try await uploadAttachment(
            sessionId: sessionId,
            uploadId: uploadId,
            path: url.path,
            fileName: resolvedName,
            onProgress: onProgress
        )
    }

    /// Chat-only — dual-purpose: cancel an in-flight upload (when
    /// `attachmentId` matches an active `uploadId`) or `DELETE` a
    /// completed attachment by server id. See
    /// `client-sdk/session/docs/contract.md#cancellation`.
    public func deleteAttachment(sessionId: String, attachmentId: String) async throws {
        guard let handle else { throw OrigonError.notInitialized }
        let handleRef = handle
        try await Task.detached {
            var err = SessionError()
            let rc = sessionId.withCString { sidPtr in
                attachmentId.withCString { aidPtr in
                    session_client_delete_attachment(handleRef, sidPtr, aidPtr, &err)
                }
            }
            if rc != 0 { throw OrigonError.consume(&err) }
        }.value
    }

    /// Blocking FFI call, intended for use from a detached task.
    private static func invokeUploadAttachment(
        handle: OpaquePointer,
        sessionId: String,
        uploadId: String,
        path: String,
        fileName: String,
        callback: SessionUploadProgressCallback?,
        ctx: UnsafeMutableRawPointer?
    ) throws -> Attachment {
        var err = SessionError()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc: Int32 = sessionId.withCString { sidPtr in
            uploadId.withCString { uidPtr in
                path.withCString { pathPtr in
                    fileName.withCString { namePtr in
                        session_client_upload_attachment(
                            handle,
                            sidPtr,
                            uidPtr,
                            pathPtr,
                            namePtr,
                            callback,
                            ctx,
                            &outJson,
                            &err
                        )
                    }
                }
            }
        }
        if rc != 0 { throw OrigonError.consume(&err) }
        guard let outJson else {
            throw OrigonError(kind: .other, message: "upload_attachment: missing response body")
        }
        defer { session_string_free(outJson) }
        let json = String(cString: outJson)
        guard let jsonData = json.data(using: .utf8) else {
            throw OrigonError(kind: .other, message: "upload_attachment: utf8 decode")
        }
        do {
            return try JSONDecoder().decode(Attachment.self, from: jsonData)
        } catch {
            throw OrigonError(
                kind: .other,
                message: "upload_attachment decode: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Events

    /// Polls the next event. Returns `nil` when the queue is idle.
    public func pollEvent() -> ClientEvent? {
        guard let handle else { return nil }
        var ev = SessionEvent()
        let kind = session_client_poll_event(handle, &ev)
        if kind == SESSION_EVENT_NONE { return nil }
        let mapped = mapEvent(ev)
        session_event_clear(&ev)
        return mapped
    }

    // MARK: - Private

    /// JSON-encode a `SendMessagePayload` for the C FFI. Throws
    /// `OrigonError.other` on encode failure.
    private static func encodePayload(_ payload: SendMessagePayload) throws -> String {
        do {
            let data = try JSONEncoder().encode(payload)
            guard let s = String(data: data, encoding: .utf8) else {
                throw OrigonError(kind: .other, message: "payload encode: utf8")
            }
            return s
        } catch let e as OrigonError {
            throw e
        } catch {
            throw OrigonError(
                kind: .other,
                message: "payload encode: \(error.localizedDescription)"
            )
        }
    }

    /// Decode the FFI's `message_json` field into a Swift `Message`.
    /// Returns `nil` on any failure (caller treats as "drop the event").
    private static func decodeMessage(_ cstr: UnsafeMutablePointer<CChar>?) -> Message? {
        guard let cstr else { return nil }
        let json = String(cString: cstr)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Message.self, from: data)
    }

    private func mapEvent(_ ev: SessionEvent) -> ClientEvent? {
        guard let sidPtr = ev.session_id else { return nil }
        let sid = String(cString: sidPtr)

        switch ev.kind {
        case SESSION_EVENT_MESSAGE_ADDED:
            guard let msg = Self.decodeMessage(ev.message_json) else { return nil }
            return .messageAdded(sessionId: sid, message: msg)

        case SESSION_EVENT_MESSAGE_UPDATED:
            guard let msg = Self.decodeMessage(ev.message_json) else { return nil }
            let updateId = ev.update_id.map { String(cString: $0) } ?? ""
            return .messageUpdated(sessionId: sid, id: updateId, message: msg)

        case SESSION_EVENT_SESSION_UPDATED:
            let new = ev.new_session_id.map { String(cString: $0) } ?? ""
            return .sessionUpdated(sessionId: sid, newSessionId: new)

        case SESSION_EVENT_CONTROL_UPDATED:
            return .controlUpdated(sessionId: sid, control: SessionControl.fromC(ev.control))

        case SESSION_EVENT_TYPING:
            return .typing(sessionId: sid, isTyping: ev.typing != 0)

        case SESSION_EVENT_CONNECTED:
            return .connected(sessionId: sid)

        case SESSION_EVENT_RECONNECTING:
            return .reconnecting(
                sessionId: sid,
                attempt: ev.reconnect_attempt,
                reason: DisconnectReason.fromC(ev.disconnect_reason)
            )

        case SESSION_EVENT_RECONNECTED:
            return .reconnected(sessionId: sid)

        case SESSION_EVENT_PEER_ATTACHED:
            let peer = ev.peer_endpoint_id.map { String(cString: $0) } ?? ""
            return .peerAttached(sessionId: sid, peerEndpointId: peer, alias: ev.peer_alias)

        case SESSION_EVENT_PEER_DETACHED:
            let peer = ev.peer_endpoint_id.map { String(cString: $0) } ?? ""
            return .peerDetached(sessionId: sid, peerEndpointId: peer, alias: ev.peer_alias)

        case SESSION_EVENT_DISCONNECTED:
            return .disconnected(
                sessionId: sid,
                reason: DisconnectReason.fromC(ev.disconnect_reason)
            )

        case SESSION_EVENT_CALL_ERROR:
            let msg: String? = ev.call_error_present != 0
                ? ev.call_error_message.map { String(cString: $0) }
                : nil
            return .callError(sessionId: sid, message: msg)

        default:
            return nil
        }
    }
}

// MARK: - Upload helpers

/// Reference wrapper so the `onProgress` closure can survive a
/// `void *ctx` round-trip across the C boundary.
private final class UploadProgressBox: @unchecked Sendable {
    let closure: @MainActor @Sendable (UploadProgress) -> Void
    init(closure: @escaping @MainActor @Sendable (UploadProgress) -> Void) {
        self.closure = closure
    }
}

// MARK: - Conversion helpers

private func withOptionalCString<R>(
    _ s: String?,
    _ body: (UnsafePointer<CChar>?) -> R
) -> R {
    if let s {
        return s.withCString { body($0) }
    } else {
        return body(nil)
    }
}

extension Channel {
    func toC() -> Int32 {
        switch self {
        case .chat: return SESSION_CHANNEL_CHAT
        case .voice: return SESSION_CHANNEL_VOICE
        }
    }

    static func fromC(_ c: Int32) -> Channel {
        c == SESSION_CHANNEL_VOICE ? .voice : .chat
    }

    static func fromWire(_ s: String) -> Channel? {
        switch s {
        case "voice": return .voice
        case "chat": return .chat
        default: return nil
        }
    }
}

extension SessionControl {
    static func fromC(_ c: Int32) -> SessionControl {
        c == SESSION_CONTROL_USER ? .user : .ai
    }
}

extension Platform {
    func toC() -> Int32 {
        switch self {
        case .none: return SESSION_PLATFORM_NONE
        case .mobile: return SESSION_PLATFORM_MOBILE
        case .web: return SESSION_PLATFORM_WEB
        }
    }
}

extension DisconnectReason {
    static func fromC(_ r: SessionDisconnectReason) -> DisconnectReason {
        switch r.kind {
        case SESSION_DISCONNECT_REASON_LOCAL_CLOSE: return .localClose
        case SESSION_DISCONNECT_REASON_NETWORK_LOSS: return .networkLoss
        case SESSION_DISCONNECT_REASON_ENDPOINT_NOT_PROVISIONED: return .endpointNotProvisioned
        case SESSION_DISCONNECT_REASON_ENDPOINT_ALREADY_CONNECTED: return .endpointAlreadyConnected
        case SESSION_DISCONNECT_REASON_TOKEN_INVALID: return .tokenInvalid
        case SESSION_DISCONNECT_REASON_TOKEN_EXPIRED: return .tokenExpired
        case SESSION_DISCONNECT_REASON_TOKEN_REPLAYED: return .tokenReplayed
        case SESSION_DISCONNECT_REASON_PROTOCOL_VIOLATION: return .protocolViolation
        case SESSION_DISCONNECT_REASON_CAPABILITY_MISSING: return .capabilityMissing
        case SESSION_DISCONNECT_REASON_ILLEGAL_STATE: return .illegalState
        case SESSION_DISCONNECT_REASON_RESOURCE_EXHAUSTED: return .resourceExhausted
        case SESSION_DISCONNECT_REASON_REPLAY_LOST: return .replayLost
        case SESSION_DISCONNECT_REASON_SESSION_ENDED: return .sessionEnded
        case SESSION_DISCONNECT_REASON_SERVER_CLOSED:
            let detail = r.server_detail.map { String(cString: $0) }
            return .serverClosed(code: r.server_code, detail: detail)
        case SESSION_DISCONNECT_REASON_TRANSPORT_CLOSED:
            let detail = r.server_detail.map { String(cString: $0) }
            return .transportClosed(detail: detail)
        default:
            let detail = r.server_detail.map { String(cString: $0) }
            return .serverClosed(code: r.server_code, detail: detail)
        }
    }
}

extension OrigonError {
    /// Read a populated `SessionError`, clear it, and return a Swift
    /// `OrigonError`. Use on every `-1` return path.
    static func consume(_ err: inout SessionError) -> OrigonError {
        let kind = OrigonError.Kind(rawValue: Int(err.kind)) ?? .unknown
        let status = Int(err.status)
        let code = err.code.map { String(cString: $0) }
        let message = err.message.map { String(cString: $0) }
        session_error_clear(&err)
        return OrigonError(kind: kind, statusCode: status, code: code, message: message)
    }
}
