# OrigonSDK

iOS and macOS SDK for the Origon platform.

## Requirements

- iOS 15.0+
- macOS 13.0+
- Xcode 15+
- Swift 5.9+

## Installation

Add the package to your `Package.swift` or through Xcode's package manager:

```swift
dependencies: [
    .package(url: "https://github.com/Origon/apple-sdk", from: "0.1.0"),
]
```

Then add `OrigonSDK` to your target's dependencies:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "OrigonSDK", package: "apple-sdk"),
    ]
),
```

The pre-built `COrigonSDK` XCFramework is downloaded automatically by SPM
from [GitHub Releases](https://github.com/Origon/apple-sdk/releases).

## Quick Start

```swift
import OrigonSDK

// Optional: install Rust-side logging once at app launch.
OrigonClient.initLogging()

// 1. Create the client.
let client = try OrigonClient(config: ClientConfig(
    endpoint: "https://api.origon.ai",
    bundleId: "com.acme.ios",
    token: "your-api-token",
    userId: "user-123"
))

// 2. Start a voice session.
let response = try client.startSession(
    StartSessionOptions(channel: .voice)
)
print("session \(response.sessionId) dialing \(response.url)")

// 3. Drain the event stream.
while true {
    guard let event = client.pollEvent() else {
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        continue
    }
    switch event {
    case .connected:                        print("connected")
    case .peerAttached(_, let peerId, _):   print("peer \(peerId)")
    case .disconnected(_, let reason):      print("disconnected: \(reason)"); return
    default: break
    }
}
```

### Voice controls

```swift
try client.setMute(id: response.sessionId, muted: true)
let onHold = try client.toggleHold(id: response.sessionId)
try client.sendDtmf(id: response.sessionId, digit: "5", durationMs: 100)
```

### Multiple sessions

```swift
let active = try client.activeSessions()
try client.setMuteAll(muted: true)
try client.endAllSessions()
```

### Joining a pre-obtained session

```swift
try client.joinSession(JoinSessionInput(
    channel: .voice,
    sessionId: "...",
    url: "...",
    token: "..."
))
```

## API Reference

### OrigonClient

| Method                                                                                                        | Description                                                                       |
| ------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `init(config:)`                                                                                               | Create a client. Throws `OrigonError` on connect failure.                         |
| `pollEvent()`                                                                                                 | Non-blocking poll. Returns `nil` when idle.                                       |
| `startSession(_:)`                                                                                            | Open a session. Returns `(sessionId, url, token)`.                                |
| `joinSession(_:)`                                                                                             | Attach to a previously-obtained `StartSessionResponse`.                           |
| `endSession(_:)` / `endAllSessions()`                                                                         | Close a single / every session.                                                   |
| `setMute(id:muted:)` / `setMuteAll(muted:)`                                                                   | Voice — absolute mute.                                                            |
| `toggleHold(id:)`                                                                                             | Voice — toggle hold. Returns the new state.                                       |
| `sendDtmf(id:digit:durationMs:)`                                                                              | Voice — send a DTMF digit per RFC 4733.                                           |
| `activeSessions()`                                                                                            | Snapshot of every active session.                                                 |
| `getSessions()`                                                                                               | `GET /sessions` — list prior sessions for the configured `userId`.                |
| `getSession(id:)`                                                                                             | `GET /session/<id>` — transcript for one session.                                 |
| `setAttributes(_:)`                                                                                           | Replace session-level attributes injected as `data.attributes` on `startSession`. |
| `startMessage` / `isChatEnabled` / `isCallEnabled` / `multipleChannels` / `attachmentPolicy` / `serverConfig` | Cached `/config` getters.                                                         |
| `OrigonClient.initLogging(filter:)`                                                                           | Install Rust-side `tracing` subscriber.                                           |

### Types

- `ClientConfig` — endpoint, bundleId, token, userId, platform, attributes (`[String: Any]?`).
- `Channel` — `.chat`, `.voice`.
- `Control` — `.agent`, `.human`.
- `Platform` — `.mobile`, `.web`, `.none`.
- `StartSessionOptions` — channel, optional sessionId, optional `data` (raw JSON).
- `StartSessionResponse` — sessionId, url, token.
- `JoinSessionInput` — channel, sessionId, url, token.
- `ActiveSession` — sessionId, channel.
- `AttachmentRule` / `AttachmentPolicy` — tenant policy for attachments.
- `ServerConfig` — full `/config` snapshot.
- `DisconnectReason` — structured disconnect reasons (incl. `.serverClosed(code:detail:)`).
- `ClientEvent` — `.connected`, `.reconnecting`, `.reconnected`, `.peerAttached`, `.peerDetached`, `.disconnected`, `.callError`, `.controlUpdated`, `.typing`, `.sessionUpdated`. Every case carries `sessionId`.
- `Message`, `Contact`, `SessionSummary`, `SessionHistory` — typed shapes returned by `getSessions()` / `getSession(id:)`.
- `OrigonError` — structured error with `kind`, `statusCode`, `code`, `message`.

Chat-side messaging and attachments (`send_message`,
`upload_attachment`, etc.) will be added when the underlying chat
plane lands in the session crate.

## License

Proprietary. All rights reserved.
