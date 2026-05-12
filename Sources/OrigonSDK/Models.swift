import Foundation

// MARK: - Enums

public enum Channel: String, Codable, Sendable {
    case chat
    case voice
}

public enum Control: Sendable {
    case agent
    case human
}

public enum Platform: Sendable {
    case none
    case mobile
    case web
}

// MARK: - Configuration / requests

/// Configuration for creating an `OrigonClient`.
public struct ClientConfig: Sendable {
    public let endpoint: String
    /// iOS application bundle identifier. When set, sent as `X-Bundle-Id`
    /// on every HTTPS call.
    public let bundleId: String?
    public let token: String?
    public let userId: String?
    public let platform: Platform
    /// Initial session-level attributes. Injected as `data.attributes`
    /// on `POST /session/start`. Encoded to a JSON string via
    /// `JSONSerialization` before crossing the native boundary; pass
    /// any valid top-level JSON object.
    public let attributes: [String: Any]?

    public init(
        endpoint: String,
        bundleId: String? = nil,
        token: String? = nil,
        userId: String? = nil,
        platform: Platform = .mobile,
        attributes: [String: Any]? = nil
    ) {
        self.endpoint = endpoint
        self.bundleId = bundleId
        self.token = token
        self.userId = userId
        self.platform = platform
        self.attributes = attributes
    }
}

/// Options for `OrigonClient.startSession`.
public struct StartSessionOptions: Sendable {
    public let channel: Channel
    /// Existing session id to resume; `nil` for a new session.
    public let sessionId: String?
    /// Optional consumer-defined raw JSON forwarded as `data` on the wire.
    public let data: String?

    /// Raw-JSON initializer. Use this when `data` is already a JSON
    /// string (or `nil` to omit it).
    public init(channel: Channel, sessionId: String? = nil, data: String? = nil) {
        self.channel = channel
        self.sessionId = sessionId
        self.data = data
    }

    /// Convenience initializer that accepts any `Encodable` value
    /// (e.g. `[String: String]` or a typed struct) and serializes it
    /// to JSON before forwarding. If encoding fails, `data` is set to
    /// `nil` — the call still proceeds, just without the optional payload.
    public init<T: Encodable>(
        channel: Channel,
        sessionId: String? = nil,
        data: T
    ) {
        self.channel = channel
        self.sessionId = sessionId
        if let bytes = try? JSONEncoder().encode(data) {
            self.data = String(data: bytes, encoding: .utf8)
        } else {
            self.data = nil
        }
    }
}

/// Response from `OrigonClient.startSession`.
public struct StartSessionResponse: Sendable {
    public let sessionId: String
    public let url: String
    /// Per-session auth token, scoped to this session only.
    public let token: String

    public init(sessionId: String, url: String, token: String) {
        self.sessionId = sessionId
        self.url = url
        self.token = token
    }
}

/// Input for `OrigonClient.joinSession` — a previously-obtained
/// `StartSessionResponse` plus the channel.
public struct JoinSessionInput: Sendable {
    public let channel: Channel
    public let sessionId: String
    public let url: String
    public let token: String

    public init(channel: Channel, sessionId: String, url: String, token: String) {
        self.channel = channel
        self.sessionId = sessionId
        self.url = url
        self.token = token
    }
}

/// Snapshot entry returned by `OrigonClient.activeSessions`.
public struct ActiveSession: Sendable {
    public let sessionId: String
    public let channel: Channel

    public init(sessionId: String, channel: Channel) {
        self.sessionId = sessionId
        self.channel = channel
    }
}

// MARK: - Server config

public struct AttachmentRule: Sendable {
    public let enabled: Bool
    /// Maximum allowed size in megabytes.
    public let maxSize: UInt32

    public init(enabled: Bool, maxSize: UInt32) {
        self.enabled = enabled
        self.maxSize = maxSize
    }
}

public struct AttachmentPolicy: Sendable {
    public let images: AttachmentRule
    public let documents: AttachmentRule
    public let videos: AttachmentRule
    public let audio: AttachmentRule

    public init(
        images: AttachmentRule,
        documents: AttachmentRule,
        videos: AttachmentRule,
        audio: AttachmentRule
    ) {
        self.images = images
        self.documents = documents
        self.videos = videos
        self.audio = audio
    }

    /// Fallback returned when the native layer refuses to hand back the
    /// policy. All categories disabled, zero size.
    public static let disabled = AttachmentPolicy(
        images: AttachmentRule(enabled: false, maxSize: 0),
        documents: AttachmentRule(enabled: false, maxSize: 0),
        videos: AttachmentRule(enabled: false, maxSize: 0),
        audio: AttachmentRule(enabled: false, maxSize: 0)
    )
}

/// Tenant configuration returned by `GET /config` at connect time.
public struct ServerConfig: Sendable {
    public let startMessage: String
    public let multipleChannels: Bool
    public let isChatEnabled: Bool
    public let isCallEnabled: Bool
    public let attachmentPolicy: AttachmentPolicy
}

// MARK: - Session history

/// One transcript line / message. Mirrors the Rust `Message` shape.
public struct Message: Codable, Sendable, Equatable {
    public let role: String
    public let id: String
    public let text: String?
    public let html: String?
    public let timestamp: String?
    public let userId: String?
    public let userName: String?

    public init(
        role: String,
        id: String,
        text: String? = nil,
        html: String? = nil,
        timestamp: String? = nil,
        userId: String? = nil,
        userName: String? = nil
    ) {
        self.role = role
        self.id = id
        self.text = text
        self.html = html
        self.timestamp = timestamp
        self.userId = userId
        self.userName = userName
    }
}

public struct Contact: Codable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Element of the array returned by `OrigonClient.getSessions`.
public struct SessionSummary: Codable, Sendable {
    public let sessionId: String
    public let subject: String
    public let channel: Channel
    public let createdAt: String
    public let updatedAt: String
    public let lastMessage: Message?
    public let contact: Contact?

    public init(
        sessionId: String,
        subject: String,
        channel: Channel,
        createdAt: String,
        updatedAt: String,
        lastMessage: Message? = nil,
        contact: Contact? = nil
    ) {
        self.sessionId = sessionId
        self.subject = subject
        self.channel = channel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessage = lastMessage
        self.contact = contact
    }
}

/// Returned by `OrigonClient.getSession`.
public struct SessionHistory: Codable, Sendable {
    public let history: [Message]

    public init(history: [Message]) {
        self.history = history
    }
}

// MARK: - Disconnect reason

public enum DisconnectReason: Sendable, Equatable {
    case localClose
    case networkLoss
    case endpointNotProvisioned
    case endpointAlreadyConnected
    case tokenInvalid
    case tokenExpired
    case tokenReplayed
    case protocolViolation
    case capabilityMissing
    case illegalState
    case resourceExhausted
    case replayLost
    case serverClosed(code: UInt64, detail: String?)
    /// Local transport failed before the MOQ session was established
    /// (QUIC dial / DNS / TLS / etc.). `detail` carries the underlying
    /// error message for diagnostics.
    case transportClosed(detail: String?)
}

// MARK: - Events

/// Async event from a session. All variants carry `sessionId` so the
/// consumer can demultiplex when several sessions are active at once.
///
/// Chat-side variants (message added/updated, tool calls) are not
/// surfaced in this iteration — `OrigonClient.pollEvent` silently skips
/// them. They will be added when the chat plane lands in the session
/// crate.
public enum ClientEvent: Sendable {
    case sessionUpdated(sessionId: String, newSessionId: String)
    case controlUpdated(sessionId: String, control: Control)
    case typing(sessionId: String, isTyping: Bool)
    case connected(sessionId: String)
    case reconnecting(sessionId: String, attempt: UInt32, reason: DisconnectReason)
    case reconnected(sessionId: String)
    case peerAttached(sessionId: String, peerEndpointId: String, alias: UInt64)
    case peerDetached(sessionId: String, peerEndpointId: String, alias: UInt64)
    case disconnected(sessionId: String, reason: DisconnectReason)
    /// Voice-side soft error. `message == nil` means a previously-
    /// surfaced error has cleared.
    case callError(sessionId: String, message: String?)

    public var sessionId: String {
        switch self {
        case .sessionUpdated(let s, _),
             .controlUpdated(let s, _),
             .typing(let s, _),
             .connected(let s),
             .reconnecting(let s, _, _),
             .reconnected(let s),
             .peerAttached(let s, _, _),
             .peerDetached(let s, _, _),
             .disconnected(let s, _),
             .callError(let s, _):
            return s
        }
    }
}

// MARK: - Errors

/// Structured error thrown by `OrigonClient`. Mirrors the Rust
/// `ClientError` discriminants — dispatch on `kind` for typed handling,
/// or read `message` / `code` for display.
public struct OrigonError: Error, Sendable, CustomStringConvertible {
    public let kind: Kind
    /// HTTP status when applicable (`.http` / `.serverUnavailable`); 0 otherwise.
    public let statusCode: Int
    /// Machine-readable code (e.g. `"user_unavailable"`) or field name (`.missingField`).
    public let code: String?
    public let message: String?

    public enum Kind: Int, Sendable {
        case unknown = 0
        case notInitialized = 1
        case noSession = 2
        case session = 3
        case missingField = 4
        case serverUnavailable = 5
        case http = 6
        case attachment = 7
        case other = 8
    }

    public init(kind: Kind, statusCode: Int = 0, code: String? = nil, message: String? = nil) {
        self.kind = kind
        self.statusCode = statusCode
        self.code = code
        self.message = message
    }

    public var description: String {
        if let message, !message.isEmpty { return message }
        if let code, !code.isEmpty { return code }
        return "OrigonError(kind: \(kind))"
    }

    public static let notInitialized = OrigonError(
        kind: .notInitialized,
        message: "Client is not initialized"
    )
}
