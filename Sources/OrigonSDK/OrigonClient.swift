import Foundation
import COrigonSDK
#if canImport(UIKit)
import UIKit
#endif

/// The primary interface to the Origon platform on Apple platforms.
///
/// Backed by the `COrigonSDK` XCFramework (statically linked
/// `libsession.a`). One instance owns one native handle and one smol
/// executor; create at app start, deinit when shutting down.
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
        let deviceId = Self.resolveDeviceId()
        // `userId` is optional at the SDK surface but required by the
        // core. Fall back to the device id so anonymous users still get
        // a stable identity. When the consumer omits `userId` and no
        // device id is available, there is nothing to identify the user
        // with — fail fast rather than send a blank id.
        guard let effectiveUserId = config.userId ?? deviceId else {
            throw OrigonError(
                kind: .missingField,
                code: "user_id",
                message: "userId was not provided and no device identifier is available"
            )
        }
        let rc: Int32 = config.endpoint.withCString { endpointPtr in
            withOptionalCString(bundleId) { bundlePtr in
                withOptionalCString(config.token) { tokenPtr in
                    effectiveUserId.withCString { userIdPtr in
                        withOptionalCString(deviceId) { deviceIdPtr in
                            withOptionalCString(attributesJson) { attrsPtr in
                                var cfg = SessionClientConfig(
                                    endpoint: endpointPtr,
                                    bundle_id: bundlePtr,
                                    token: tokenPtr,
                                    user_id: userIdPtr,
                                    device_id: deviceIdPtr,
                                    attributes_json: attrsPtr
                                )
                                return session_client_create(&cfg, &newHandle, &err)
                            }
                        }
                    }
                }
            }
        }
        guard rc == 0, let newHandle else {
            throw OrigonError.consume(&err)
        }
        self.handle = newHandle
        // Become the active client for push registration and flush any
        // token buffered before initialization. See `Push.swift`.
        PushRegistrar.shared.attach(self)
    }

    /// Resolve a stable per-install device identifier.
    ///
    /// iOS (and the UIKit-backed platforms) use
    /// `identifierForVendor`, which is stable across launches and resets
    /// only when every app from this vendor is removed. Platforms without
    /// UIKit (macOS) return `nil`, which disables push registration and,
    /// when no `userId` is supplied, surfaces as an init error.
    private static func resolveDeviceId() -> String? {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
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
        // No explicit push detach needed: PushRegistrar holds the client
        // weakly, so its reference auto-nils when we deallocate.
        if let handle {
            session_client_destroy(handle)
        }
    }

    // MARK: - Push notifications (internal)

    /// Blocking FFI call — invoked off the main thread by
    /// ``PushRegistrar``. The public, buffering entry point is the static
    /// ``OrigonClient/registerForPushNotifications(deviceToken:environment:)``.
    func registerPush(token: String, provider: String, environment: String?) throws {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        let rc: Int32 = token.withCString { tokenPtr in
            provider.withCString { providerPtr in
                withOptionalCString(environment) { envPtr in
                    session_client_register_push(handle, tokenPtr, providerPtr, envPtr, &err)
                }
            }
        }
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    /// Blocking FFI call — invoked off the main thread by ``PushRegistrar``.
    func unregisterPush() throws {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        let rc = session_client_unregister_push(handle, &err)
        if rc != 0 { throw OrigonError.consume(&err) }
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
    /// on subsequent `startCall` / `startChat` calls. Pass `nil` to clear.
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
    /// Start a **voice call**. Posts `/session/start` and brings the media
    /// plane up.
    ///
    /// **Returning does not mean the media plane is connected.** The MoQ dial
    /// runs in the background: connect success arrives as a `.connected`
    /// event and a dial failure as `.disconnected` (reason
    /// `.transportClosed`) on the event stream — *not* as a thrown error.
    /// Calling ``endSession(_:)`` with the returned id while still dialing
    /// cancels the in-flight dial. Throws only for the `/session/start` HTTP
    /// failure or a malformed request.
    public func startCall(_ options: StartCallOptions) throws -> StartSessionResponse {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        var resp = SessionStartResponse()

        let rc: Int32 = withOptionalCString(options.sessionId) { sidPtr in
            withOptionalCString(options.data) { dataPtr in
                var opts = SessionStartCallOptions(
                    session_id: sidPtr,
                    data_json: dataPtr
                )
                return session_client_start_call(handle, &opts, &resp, &err)
            }
        }
        return try Self.consumeStartResponse(rc, &resp, &err)
    }

    /// Start a **chat**, sending the visitor's first message as part of the
    /// call.
    ///
    /// The first message is required — see ``StartChatOptions`` for why. The
    /// session id comes back BEFORE the message is sent, so the provisional
    /// `.messageAdded` event always has a session to belong to.
    ///
    /// A first message that fails to DELIVER does not throw: the session is
    /// live and the failure arrives as `.messageUpdated` with
    /// `status == .failed`, so the user can retry. Only a TERMINAL refusal
    /// (the session is already gone) throws — returning normally would leave
    /// the app rendering a composer on a dead conversation.
    public func startChat(_ options: StartChatOptions) throws -> StartSessionResponse {
        guard let handle else { throw OrigonError.notInitialized }
        let firstJson = try Self.encodePayload(options.firstMessage)
        var err = SessionError()
        var resp = SessionStartResponse()

        let rc: Int32 = firstJson.withCString { firstPtr in
            withOptionalCString(options.sessionId) { sidPtr in
                withOptionalCString(options.data) { dataPtr in
                    var opts = SessionStartChatOptions(
                        first_message_json: firstPtr,
                        session_id: sidPtr,
                        data_json: dataPtr
                    )
                    return session_client_start_chat(handle, &opts, &resp, &err)
                }
            }
        }
        return try Self.consumeStartResponse(rc, &resp, &err)
    }

    private static func consumeStartResponse(
        _ rc: Int32,
        _ resp: inout SessionStartResponse,
        _ err: inout SessionError
    ) throws -> StartSessionResponse {
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

    /// Attach to a **voice call** whose ``StartSessionResponse`` was obtained
    /// out of band (multi-device handoff, deeplink, persisted session).
    ///
    /// Like ``startCall(_:)``, the MoQ dial runs in the background —
    /// returning here does not mean it is connected; await the `.connected` /
    /// `.disconnected` event.
    public func joinCall(_ input: JoinInput) throws {
        try join(input) { handle, raw, err in
            session_client_join_call(handle, raw, err)
        }
    }

    /// Attach to an existing **chat** obtained out of band — the agent /
    /// chat-offered path. Completes the attach before returning.
    ///
    /// Takes no first message, unlike ``startChat(_:)``: joining is entering
    /// a room whose first-message gate is ALREADY released — the visitor has
    /// spoken, which is why this participant is being offered the
    /// conversation — so there is no deadline left to race.
    public func joinChat(_ input: JoinInput) throws {
        try join(input) { handle, raw, err in
            session_client_join_chat(handle, raw, err)
        }
    }

    private func join(
        _ input: JoinInput,
        _ call: (OpaquePointer, UnsafePointer<SessionJoinInput>, UnsafeMutablePointer<SessionError>) -> Int32
    ) throws {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        let rc: Int32 = input.sessionId.withCString { sidPtr in
            input.url.withCString { urlPtr in
                input.token.withCString { tokPtr in
                    var raw = SessionJoinInput(
                        session_id: sidPtr,
                        url: urlPtr,
                        token: tokPtr
                    )
                    return call(handle, &raw, &err)
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

    /// Override the audio output route (speaker / receiver / Bluetooth).
    ///
    /// Process-global — affects the app's single active voice session, so it
    /// takes no session id. On iOS this maps to
    /// `AVAudioSession.overrideOutputAudioPort`, and the SDK re-asserts the
    /// route across reconnects and OS route changes. A no-op when no call is
    /// active. Higher-level UI typically wraps this as a boolean speaker toggle
    /// (`.speaker` / `.automatic`).
    public func setAudioOutput(_ route: AudioOutputRoute) throws {
        guard let handle else { throw OrigonError.notInitialized }
        var err = SessionError()
        let rc = session_client_set_audio_output(handle, route.rawValue, &err)
        if rc != 0 { throw OrigonError.consume(&err) }
    }

    // MARK: - Chat

    /// Chat-only — send a text / HTML message on the named session.
    ///
    /// Requires an active chat session for `id` (call ``startChat``
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

    /// Stream a file at `path` to the WIDGET this client was created
    /// for and return the server-issued ``Attachment``.
    ///
    /// There is no `sessionId` and no session prerequisite — an
    /// attachment can be the first thing a visitor sends.
    ///
    /// For security-scoped `URL`s from `UIDocumentPicker` use the
    /// `url:` overload; for in-memory `Data` use the `data:` overload.
    /// Pass `uploadId` (default: fresh UUID) and hand the same value to
    /// ``deleteAttachment(attachmentId:)`` to cancel in-flight.
    /// `onProgress` is invoked on `@MainActor`.
    ///
    /// See `client-sdk/session/docs/contract.md#attachment-flow` for
    /// MIME detection, policy prechecks, and error code semantics.
    public func uploadAttachment(
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
            uploadId: uploadId,
            path: url.path,
            fileName: resolvedName,
            onProgress: onProgress
        )
    }

    /// Dual-purpose: cancel an in-flight upload (when `attachmentId`
    /// matches an active `uploadId`) or `DELETE` a completed attachment
    /// by server id. Session-less like ``uploadAttachment(uploadId:path:fileName:onProgress:)``.
    /// See `client-sdk/session/docs/contract.md#cancellation`.
    public func deleteAttachment(attachmentId: String) async throws {
        guard let handle else { throw OrigonError.notInitialized }
        let handleRef = handle
        try await Task.detached {
            var err = SessionError()
            let rc = attachmentId.withCString { aidPtr in
                session_client_delete_attachment(handleRef, aidPtr, &err)
            }
            if rc != 0 { throw OrigonError.consume(&err) }
        }.value
    }

    /// Blocking FFI call, intended for use from a detached task.
    private static func invokeUploadAttachment(
        handle: OpaquePointer,
        uploadId: String,
        path: String,
        fileName: String,
        callback: SessionUploadProgressCallback?,
        ctx: UnsafeMutableRawPointer?
    ) throws -> Attachment {
        var err = SessionError()
        var outJson: UnsafeMutablePointer<CChar>?
        let rc: Int32 = uploadId.withCString { uidPtr in
            path.withCString { pathPtr in
                fileName.withCString { namePtr in
                    session_client_upload_attachment(
                        handle,
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

    /// Wire shape of the `chatSessionEnded` payload, which rides the FFI's
    /// `message_json` slot as `{reason, acw?}` (same field the message
    /// events use). `acw` is present only on an agent participant's stream.
    private struct SessionEndedPayload: Decodable {
        let reason: String
        let acw: Acw?

        private enum CodingKeys: String, CodingKey { case reason, acw }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
            self.acw = try c.decodeIfPresent(Acw.self, forKey: .acw)
        }
    }

    /// Decode the `chatSessionEnded` payload from `message_json`. A missing
    /// or malformed payload degrades to an empty reason with no ACW — the
    /// clean-end signal itself (the event kind) is what matters.
    private static func decodeSessionEnded(_ cstr: UnsafeMutablePointer<CChar>?) -> (reason: String, acw: Acw?) {
        guard let cstr else { return ("", nil) }
        let json = String(cString: cstr)
        guard
            let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(SessionEndedPayload.self, from: data)
        else { return ("", nil) }
        return (payload.reason, payload.acw)
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

        case SESSION_EVENT_AUDIO_ROUTE_CHANGED:
            let route = AudioOutputRoute(rawValue: ev.audio_route) ?? .automatic
            return .audioRouteChanged(sessionId: sid, route: route)

        case SESSION_EVENT_CHAT_SESSION_ENDED:
            let ended = Self.decodeSessionEnded(ev.message_json)
            return .chatSessionEnded(sessionId: sid, reason: ended.reason, acw: ended.acw)

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

// `Channel` no longer crosses the C boundary as an integer: the split into
// startCall/startChat + joinCall/joinChat removed the runtime discriminator
// every signature used to carry, so `SESSION_CHANNEL_*` is gone from the
// bridge header. The enum survives only where the SERVER names a channel in
// a JSON payload — hence `fromWire` below and no `toC` / `fromC`.
extension Channel {

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
