import Foundation
import COrigonSDK

/// The primary interface to the Origon platform.
///
/// Create an instance with a ``ClientConfig``, then call methods to manage
/// sessions, send messages, and handle attachments. Poll for server-pushed
/// events with ``pollEvent()``.
public final class OrigonClient: @unchecked Sendable {
    private var handle: OpaquePointer?

    /// Creates a new client connected to the Origon platform.
    public init(config: ClientConfig) throws {
        var cConfig = config.endpoint.withCString { endpoint in
            config.token.withCString { token in
                config.userId.withCString { userId in
                    OrigonConfig(
                        endpoint: endpoint,
                        token: token,
                        user_id: userId
                    )
                }
            }
        }
        let ptr = origon_client_create(&cConfig)
        guard let ptr else {
            throw OrigonError.clientCreationFailed
        }
        self.handle = ptr
    }

    deinit {
        if let handle {
            origon_client_destroy(handle)
        }
    }

    /// Polls for the next event from the server. Returns `nil` when no event is available.
    public func pollEvent() -> ClientEvent? {
        guard let handle else { return nil }
        var event = origon_client_poll_event(handle)
        defer { origon_event_free(&event) }
        return convertEvent(event)
    }

    /// Starts a new session or resumes an existing one.
    public func startSession(_ options: StartSessionOptions) throws -> SessionInfo {
        guard let handle else { throw OrigonError.sessionStartFailed }

        let result: Int32
        var out = OrigonSessionInfo()

        if let sessionId = options.sessionId {
            result = sessionId.withCString { sid in
                var opts = OrigonStartSessionOptions(
                    channel: options.channel.toCChannel(),
                    session_id: sid,
                    fetch_session: options.fetchSession ? 1 : 0
                )
                return origon_client_start_session(handle, &opts, &out)
            }
        } else {
            var opts = OrigonStartSessionOptions(
                channel: options.channel.toCChannel(),
                session_id: nil,
                fetch_session: options.fetchSession ? 1 : 0
            )
            result = origon_client_start_session(handle, &opts, &out)
        }

        guard result == 0 else { throw OrigonError.sessionStartFailed }
        defer { origon_session_info_free(&out) }
        return convertSessionInfo(out)
    }

    /// Fetches all session summaries.
    public func getSessions() throws -> [SessionSummary] {
        guard let handle else { throw OrigonError.sessionsFetchFailed }
        var out = OrigonSessionList()
        let result = origon_client_get_sessions(handle, &out)
        guard result == 0 else { throw OrigonError.sessionsFetchFailed }
        defer { origon_session_list_free(&out) }
        return convertSessionList(out)
    }

    /// Fetches the control state and messages of a specific session.
    public func getSession(sessionId: String) throws -> (Control, [Message]) {
        guard let handle else { throw OrigonError.sessionFetchFailed }
        var out = OrigonGetSessionResult()
        let result = sessionId.withCString { sid in
            origon_client_get_session(handle, sid, &out)
        }
        guard result == 0 else { throw OrigonError.sessionFetchFailed }
        defer { origon_get_session_result_free(&out) }
        let control = Control.fromC(out.control)
        let messages = convertMessages(out.messages, count: out.messages_len)
        return (control, messages)
    }

    /// Ends the current active session.
    public func endSession() throws {
        guard let handle else { throw OrigonError.sessionEndFailed }
        let result = origon_client_end_session(handle)
        guard result == 0 else { throw OrigonError.sessionEndFailed }
    }

    /// Sends a message in the current session. Returns the session ID.
    public func sendMessage(_ payload: SendMessagePayload) throws -> String {
        guard let handle else { throw OrigonError.sendMessageFailed }

        var outSessionId: UnsafeMutablePointer<CChar>?
        let result = withSendMessagePayload(payload) { cPayload in
            var p = cPayload
            return origon_client_send_message(handle, &p, &outSessionId)
        }

        guard result == 0, let outSessionId else {
            throw OrigonError.sendMessageFailed
        }
        defer { origon_string_free(outSessionId) }
        return String(cString: outSessionId)
    }

    /// Uploads an attachment. Returns the attachment info and an async stream of upload progress.
    public func uploadAttachment(data: Data, filename: String) throws -> (AttachmentInfo, AsyncStream<UploadProgress>) {
        guard let handle else { throw OrigonError.uploadFailed }

        var out = OrigonUploadResult()
        let result = data.withUnsafeBytes { rawBuf in
            guard let baseAddr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(-1)
            }
            return filename.withCString { fname in
                origon_client_upload_attachment(handle, baseAddr, UInt32(data.count), fname, &out)
            }
        }

        guard result == 0 else { throw OrigonError.uploadFailed }

        let attachment = AttachmentInfo(
            mediaId: String(cString: out.attachment.media_id),
            url: String(cString: out.attachment.url)
        )

        let progressHandle = out.progress_handle
        let stream = AsyncStream<UploadProgress> { continuation in
            guard let progressHandle else {
                continuation.finish()
                return
            }
            Task.detached {
                while true {
                    var progress = OrigonUploadProgress()
                    let pollResult = origon_progress_poll(progressHandle, &progress)
                    if pollResult == 0 {
                        continuation.yield(UploadProgress(
                            percent: progress.percent,
                            loaded: progress.loaded,
                            total: progress.total
                        ))
                        if progress.percent >= 100.0 {
                            break
                        }
                    } else {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                }
                origon_progress_free(progressHandle)
                continuation.finish()
            }
        }

        // Free the upload result (but not the progress handle, which is consumed by the stream).
        origon_attachment_info_free(&out.attachment)

        return (attachment, stream)
    }

    /// Deletes a previously uploaded attachment.
    public func deleteAttachment(mediaId: String) throws {
        guard let handle else { throw OrigonError.deleteFailed }
        let result = mediaId.withCString { mid in
            origon_client_delete_attachment(handle, mid)
        }
        guard result == 0 else { throw OrigonError.deleteFailed }
    }

    /// Returns the download URL for an attachment.
    public func getAttachmentUrl(mediaId: String) -> String? {
        guard let handle else { return nil }
        let cStr = mediaId.withCString { mid in
            origon_client_get_attachment_url(handle, mid)
        }
        guard let cStr else { return nil }
        defer { origon_string_free(cStr) }
        return String(cString: cStr)
    }

    /// Toggles the mute state for voice sessions. Returns the new mute state.
    public func toggleMute() throws -> Bool {
        guard let handle else { throw OrigonError.muteFailed }
        var muted: Int32 = 0
        let result = origon_client_toggle_mute(handle, &muted)
        guard result == 0 else { throw OrigonError.muteFailed }
        return muted != 0
    }
}

// MARK: - Private C-to-Swift Conversions

private extension OrigonClient {

    func convertEvent(_ event: OrigonEvent) -> ClientEvent? {
        switch event.event_type {
        case ORIGON_EVENT_MESSAGE_ADDED:
            return .messageAdded(message: convertMessage(event.message), index: event.index)
        case ORIGON_EVENT_MESSAGE_UPDATED:
            return .messageUpdated(message: convertMessage(event.message), index: event.index)
        case ORIGON_EVENT_SESSION_UPDATED:
            let sid = event.session_id.map { String(cString: $0) } ?? ""
            return .sessionUpdated(sessionId: sid)
        case ORIGON_EVENT_CONTROL_UPDATED:
            return .controlUpdated(control: Control.fromC(event.control))
        case ORIGON_EVENT_TOOL_CALLS:
            let calls = convertToolCalls(event.tool_calls, count: event.tool_calls_len)
            return .toolCalls(calls: calls)
        case ORIGON_EVENT_TYPING:
            return .typing(isTyping: event.typing != 0)
        case ORIGON_EVENT_CALL_STATUS:
            let status = event.call_status.map { String(cString: $0) } ?? ""
            return .callStatus(status: status)
        case ORIGON_EVENT_CALL_ERROR:
            let error: String? = event.call_error_present != 0
                ? event.call_error.map { String(cString: $0) }
                : nil
            return .callError(error: error)
        case ORIGON_EVENT_NONE:
            return nil
        default:
            return nil
        }
    }

    func convertMessage(_ msg: OrigonMessage) -> Message {
        Message(
            role: MessageRole.fromC(msg.role),
            text: msg.text.map { String(cString: $0) },
            html: msg.html.map { String(cString: $0) },
            timestamp: msg.timestamp.map { String(cString: $0) },
            loading: msg.loading != 0,
            done: msg.done != 0,
            errorText: msg.error_text.map { String(cString: $0) },
            attachments: convertAttachments(msg.attachments, count: msg.attachments_len),
            toolCalls: convertToolCalls(msg.tool_calls, count: msg.tool_calls_len),
            toolCallId: msg.tool_call_id.map { String(cString: $0) },
            toolName: msg.tool_name.map { String(cString: $0) },
            meta: convertKeyValues(msg.meta, count: msg.meta_len)
        )
    }

    func convertMessages(_ ptr: UnsafeMutablePointer<OrigonMessage>?, count: UInt32) -> [Message] {
        guard let ptr, count > 0 else { return [] }
        return (0..<Int(count)).map { convertMessage(ptr[$0]) }
    }

    func convertAttachments(_ ptr: UnsafeMutablePointer<OrigonAttachmentInfo>?, count: UInt32) -> [AttachmentInfo] {
        guard let ptr, count > 0 else { return [] }
        return (0..<Int(count)).map {
            AttachmentInfo(
                mediaId: String(cString: ptr[$0].media_id),
                url: String(cString: ptr[$0].url)
            )
        }
    }

    func convertAttachmentsConst(_ ptr: UnsafePointer<OrigonAttachmentInfo>?, count: UInt32) -> [AttachmentInfo] {
        guard let ptr, count > 0 else { return [] }
        return (0..<Int(count)).map {
            AttachmentInfo(
                mediaId: String(cString: ptr[$0].media_id),
                url: String(cString: ptr[$0].url)
            )
        }
    }

    func convertToolCalls(_ ptr: UnsafeMutablePointer<OrigonToolCall>?, count: UInt32) -> [ToolCall] {
        guard let ptr, count > 0 else { return [] }
        return (0..<Int(count)).map {
            let tc = ptr[$0]
            let args: Data
            if let argPtr = tc.arguments, tc.arguments_len > 0 {
                args = Data(bytes: argPtr, count: Int(tc.arguments_len))
            } else {
                args = Data()
            }
            return ToolCall(
                toolCallId: String(cString: tc.tool_call_id),
                toolName: String(cString: tc.tool_name),
                arguments: args
            )
        }
    }

    func convertKeyValues(_ ptr: UnsafeMutablePointer<OrigonKeyValue>?, count: UInt32) -> [String: String]? {
        guard let ptr, count > 0 else { return nil }
        var dict = [String: String]()
        for i in 0..<Int(count) {
            let key = String(cString: ptr[i].key)
            let value = String(cString: ptr[i].value)
            dict[key] = value
        }
        return dict
    }

    func convertKeyValuesConst(_ ptr: UnsafePointer<OrigonKeyValue>?, count: UInt32) -> [String: String] {
        guard let ptr, count > 0 else { return [:] }
        var dict = [String: String]()
        for i in 0..<Int(count) {
            let key = String(cString: ptr[i].key)
            let value = String(cString: ptr[i].value)
            dict[key] = value
        }
        return dict
    }

    func convertSessionInfo(_ info: OrigonSessionInfo) -> SessionInfo {
        SessionInfo(
            sessionId: String(cString: info.session_id),
            messages: convertMessages(info.messages, count: info.messages_len),
            control: Control.fromC(info.control),
            configData: convertKeyValuesConst(info.config_data, count: info.config_data_len),
            active: info.active != 0
        )
    }

    func convertSessionList(_ list: OrigonSessionList) -> [SessionSummary] {
        guard let items = list.items, list.len > 0 else { return [] }
        return (0..<Int(list.len)).map { i in
            let s = items[i]
            return SessionSummary(
                sessionId: String(cString: s.session_id),
                channel: Channel.fromC(s.channel),
                createdAt: String(cString: s.created_at),
                updatedAt: String(cString: s.updated_at),
                lastMessage: convertMessage(s.last_message)
            )
        }
    }

    func withSendMessagePayload<R>(
        _ payload: SendMessagePayload,
        body: (OrigonSendMessagePayload) -> R
    ) -> R {
        let textCStr = payload.text.map { strdup($0) }
        let htmlCStr = payload.html.map { strdup($0) }
        let typeCStr = payload.type.map { strdup($0) }

        defer {
            textCStr.map { free($0) }
            htmlCStr.map { free($0) }
            typeCStr.map { free($0) }
        }

        // Convert attachments
        var cAttachments = payload.attachments.map { att -> OrigonAttachmentInfo in
            OrigonAttachmentInfo(
                media_id: strdup(att.mediaId),
                url: strdup(att.url)
            )
        }
        defer {
            for i in 0..<cAttachments.count {
                free(cAttachments[i].media_id)
                free(cAttachments[i].url)
            }
        }

        // Convert meta
        var cMeta = payload.meta.map { (k, v) -> OrigonKeyValue in
            OrigonKeyValue(key: strdup(k), value: strdup(v))
        }
        defer {
            for i in 0..<cMeta.count {
                free(cMeta[i].key)
                free(cMeta[i].value)
            }
        }

        // Convert results to buffers
        return payload.context.withOptionalUnsafeBytes { contextBuf in
            withArrayOfOrigonBuffers(payload.results) { buffers in
                cAttachments.withUnsafeMutableBufferPointer { attBuf in
                    cMeta.withUnsafeMutableBufferPointer { metaBuf in
                        let cPayload = OrigonSendMessagePayload(
                            text: textCStr.map { UnsafePointer($0) },
                            html: htmlCStr.map { UnsafePointer($0) },
                            context: contextBuf?.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            context_len: UInt32(contextBuf?.count ?? 0),
                            attachments: attBuf.baseAddress.map { UnsafePointer($0) },
                            attachments_len: UInt32(payload.attachments.count),
                            type: typeCStr.map { UnsafePointer($0) },
                            results: buffers.baseAddress.map { UnsafePointer($0) },
                            results_len: UInt32(payload.results.count),
                            meta: metaBuf.baseAddress.map { UnsafePointer($0) },
                            meta_len: UInt32(payload.meta.count)
                        )
                        return body(cPayload)
                    }
                }
            }
        }
    }
}

// MARK: - Private Helpers

private extension Channel {
    func toCChannel() -> OrigonChannel {
        switch self {
        case .chat: return ORIGON_CHANNEL_CHAT
        case .voice: return ORIGON_CHANNEL_VOICE
        }
    }

    static func fromC(_ c: OrigonChannel) -> Channel {
        switch c {
        case ORIGON_CHANNEL_VOICE: return .voice
        default: return .chat
        }
    }
}

private extension Control {
    static func fromC(_ c: OrigonControl) -> Control {
        switch c {
        case ORIGON_CONTROL_HUMAN: return .human
        default: return .agent
        }
    }
}

private extension MessageRole {
    static func fromC(_ c: OrigonMessageRole) -> MessageRole {
        switch c {
        case ORIGON_MESSAGE_ROLE_USER: return .user
        case ORIGON_MESSAGE_ROLE_SUPERVISOR: return .supervisor
        case ORIGON_MESSAGE_ROLE_SYSTEM: return .system
        case ORIGON_MESSAGE_ROLE_TOOL: return .tool
        default: return .assistant
        }
    }
}

private extension Optional where Wrapped == Data {
    func withOptionalUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer?) -> R) -> R {
        switch self {
        case .some(let data):
            return data.withUnsafeBytes { body($0) }
        case .none:
            return body(nil)
        }
    }
}

private func withArrayOfOrigonBuffers<R>(_ dataArray: [Data], body: (UnsafeMutableBufferPointer<OrigonBuffer>) -> R) -> R {
    if dataArray.isEmpty {
        return body(UnsafeMutableBufferPointer(start: nil, count: 0))
    }

    // Pin each Data and build OrigonBuffer array
    var buffers = [OrigonBuffer]()
    buffers.reserveCapacity(dataArray.count)

    // We need to keep NSData references alive
    let nsDatas = dataArray.map { $0 as NSData }
    for ns in nsDatas {
        buffers.append(OrigonBuffer(
            data: ns.bytes.assumingMemoryBound(to: UInt8.self),
            len: UInt32(ns.length)
        ))
    }

    return buffers.withUnsafeMutableBufferPointer { body($0) }
}
