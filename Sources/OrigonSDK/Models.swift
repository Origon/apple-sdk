import Foundation

// MARK: - Enums

/// The communication channel for a session.
public enum Channel: Sendable {
    case chat
    case voice
}

/// Who currently controls the session.
public enum Control: Sendable {
    case agent
    case human
}

/// The role of a message sender.
public enum MessageRole: Sendable {
    case assistant
    case user
    case supervisor
    case system
    case tool
}

// MARK: - Core Types

/// A single message in a session.
public struct Message: Sendable {
    public let role: MessageRole
    public let text: String?
    public let html: String?
    public let timestamp: String?
    public let loading: Bool
    public let done: Bool
    public let errorText: String?
    public let attachments: [AttachmentInfo]
    public let toolCalls: [ToolCall]
    public let toolCallId: String?
    public let toolName: String?
    public let meta: [String: String]?

    public init(
        role: MessageRole,
        text: String? = nil,
        html: String? = nil,
        timestamp: String? = nil,
        loading: Bool = false,
        done: Bool = false,
        errorText: String? = nil,
        attachments: [AttachmentInfo] = [],
        toolCalls: [ToolCall] = [],
        toolCallId: String? = nil,
        toolName: String? = nil,
        meta: [String: String]? = nil
    ) {
        self.role = role
        self.text = text
        self.html = html
        self.timestamp = timestamp
        self.loading = loading
        self.done = done
        self.errorText = errorText
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.meta = meta
    }
}

/// Full session information returned when starting or fetching a session.
public struct SessionInfo: Sendable {
    public let sessionId: String
    public let messages: [Message]
    public let control: Control
    public let configData: [String: String]
    public let active: Bool
}

/// Summary of a session for listing purposes.
public struct SessionSummary: Sendable {
    public let sessionId: String
    public let title: String?
    public let channel: Channel
    public let createdAt: String
    public let updatedAt: String
    public let lastMessage: Message
}

/// Options for starting a new session.
public struct StartSessionOptions: Sendable {
    public let channel: Channel
    public let sessionId: String?
    public let fetchSession: Bool

    public init(channel: Channel, sessionId: String? = nil, fetchSession: Bool = false) {
        self.channel = channel
        self.sessionId = sessionId
        self.fetchSession = fetchSession
    }
}

/// Payload for sending a message.
public struct SendMessagePayload: Sendable {
    public let text: String?
    public let html: String?
    public let context: Data?
    public let attachments: [AttachmentInfo]
    public let type: String?
    public let results: [Data]
    public let meta: [String: String]

    public init(
        text: String? = nil,
        html: String? = nil,
        context: Data? = nil,
        attachments: [AttachmentInfo] = [],
        type: String? = nil,
        results: [Data] = [],
        meta: [String: String] = [:]
    ) {
        self.text = text
        self.html = html
        self.context = context
        self.attachments = attachments
        self.type = type
        self.results = results
        self.meta = meta
    }
}

/// A tool invocation within a message.
public struct ToolCall: Sendable {
    public let toolCallId: String
    public let toolName: String
    public let arguments: Data

    public init(toolCallId: String, toolName: String, arguments: Data) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.arguments = arguments
    }
}

/// Information about an uploaded attachment.
public struct AttachmentInfo: Sendable {
    public let mediaId: String
    public let url: String

    public init(mediaId: String, url: String) {
        self.mediaId = mediaId
        self.url = url
    }
}

/// Progress update for an ongoing upload.
public struct UploadProgress: Sendable {
    public let percent: Double
    public let loaded: UInt64
    public let total: UInt64
}

/// Configuration for creating an OrigonClient.
public struct ClientConfig: Sendable {
    public let endpoint: String
    /// iOS app bundle identifier (e.g. `com.acme.ios`). Required — the
    /// server reads it on `GET /config` to pick the right tenant.
    public let bundleId: String
    public let token: String?
    public let userId: String

    public init(endpoint: String, bundleId: String, token: String? = nil, userId: String) {
        self.endpoint = endpoint
        self.bundleId = bundleId
        self.token = token
        self.userId = userId
    }
}

// MARK: - Events

/// An event received from the server.
public enum ClientEvent: Sendable {
    case messageAdded(message: Message, index: UInt32)
    case messageUpdated(message: Message, index: UInt32)
    case sessionUpdated(sessionId: String)
    case controlUpdated(control: Control)
    case toolCalls(calls: [ToolCall])
    case typing(isTyping: Bool)
    case callStatus(status: String)
    case callError(error: String?)
}

// MARK: - Server config

/// Tenant configuration returned by `GET /config` at connect time.
/// Exposed so consumers can gate UI on chat/call availability, render
/// attachment limits, or read the start message.
public struct ServerConfig: Sendable {
    public let startMessage: String
    public let concurrentChannels: Bool
    public let isChatEnabled: Bool
    public let isCallEnabled: Bool
    public let attachmentPolicy: AttachmentPolicy
}

public struct AttachmentPolicy: Sendable {
    public let images: AttachmentRule
    public let documents: AttachmentRule
    public let videos: AttachmentRule
    public let audio: AttachmentRule
}

public struct AttachmentRule: Sendable {
    public let enabled: Bool
    /// Maximum allowed size in megabytes.
    public let maxSize: UInt32
}

// MARK: - Errors

/// Structured reason why `OrigonClient(config:)` failed.
///
/// The associated values mirror the server's error envelope where
/// applicable so the host app can dispatch on `code`
/// (e.g. `bundle_id_not_allowed`) rather than string-matching messages.
public enum ConnectError: Error, Sendable, Equatable {
    /// `field` names the missing input — `endpoint` or `bundle_id`.
    case missingField(field: String)
    /// DNS/TLS/connect/timeout/body-decode failure.
    case transport(message: String)
    /// 403 from the server; `code` is the machine-readable envelope code.
    case forbidden(code: String, message: String)
    /// Other non-2xx, non-5xx response with the envelope attached.
    case http(status: Int, code: String, message: String)
    /// 5xx — treat as transient and let the user retry.
    case serverUnavailable(status: Int)
    /// Unexpected native-layer failure.
    case unknown(message: String)
}

/// Errors thrown by OrigonClient operations.
public enum OrigonError: Error, Sendable {
    case clientCreationFailed(ConnectError)
    case notInitialized
    case sessionStartFailed
    case sessionsFetchFailed
    case sessionFetchFailed
    case sessionEndFailed
    case sendMessageFailed
    case uploadFailed
    case deleteFailed
    case muteFailed
}
