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

## Host App Configuration

iOS reads permission and capability declarations only from the **main
bundle's** `Info.plist` — keys placed inside an embedded framework are
ignored at runtime. The following entries must be added by the
integrating app.

### Required: microphone permission

Voice sessions request audio recording via `AVAudioSession`. Without
this key the app crashes the first time a call starts.

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access is required for voice calls.</string>
```

### Optional: background voice calls

If calls must continue while the app is backgrounded (e.g. the user
locks the screen mid-call), declare the `audio` background mode:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>
```

If you integrate with CallKit / PushKit for system call UI, also add
`voip` to the same array.

## Quick Start

```swift
import OrigonSDK

// Optional: install Rust-side logging once at app launch.
OrigonClient.initLogging()

// 1. Create the client.
let client = try OrigonClient(config: ClientConfig(
    endpoint: "https://api.origon.ai",
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

### Chat

`sendMessage`, `notifyTyping`, and `stopTyping` all require an active
chat session. **Call `startSession(channel: .chat, ...)` first** —
otherwise these throw `OrigonError(kind: .noSession)`. The same
applies after `endSession(id:)`.

```swift
// Outbound send. The SDK fires `.messageAdded` (status `.sending`)
// before the wire round-trip and `.messageUpdated` (delivered or
// failed) after — both surface on `pollEvent()`. The return value is
// the server-issued Message.
let msg = try client.sendMessage(
    id: sessionId,
    payload: SendMessagePayload(text: "hello", html: "hello")
)

// Typing — call per keystroke. The SDK debounces; only one outbound
// `{state: "on"}` fires per typing burst, and a `{state: "off"}` is
// auto-emitted after ~3 s of no further calls. Fire `stopTyping(id:)`
// explicitly when the input clears (e.g. user deleted all text) to
// snap the peer's "typing…" indicator off instantly.
try client.notifyTyping(id: sessionId)
try client.stopTyping(id: sessionId)
```

Polling chat events:

```swift
while let event = client.pollEvent() {
    switch event {
    case .messageAdded(let sid, let message):
        // Store under message.localId ?? message.id
    case .messageUpdated(let sid, let id, let message):
        // Look up the row by id (matches the original localId / message.id)
    case .typing(let sid, let isTyping):
        // Show / hide "typing…" indicator
    default: break
    }
}
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
| `sendMessage(id:payload:)`                                                                                    | Chat — POST `<sessionUrl>/message`. Returns the server-issued `Message`. Fires `.messageAdded` then `.messageUpdated`. |
| `notifyTyping(id:)`                                                                                           | Chat — register a keystroke; SDK debounces outbound `/typing` POSTs.              |
| `stopTyping(id:)`                                                                                             | Chat — force outbound typing state to "off" immediately.                          |
| `activeSessions()`                                                                                            | Snapshot of every active session.                                                 |
| `getSessions()`                                                                                               | `GET /sessions` — list prior sessions for the configured `userId`.                |
| `getSession(id:)`                                                                                             | `GET /session/<id>` — transcript for one session.                                 |
| `setAttributes(_:)`                                                                                           | Replace session-level attributes injected as `data.attributes` on `startSession`. |
| `startMessage` / `isChatEnabled` / `isCallEnabled` / `multipleChannels` / `attachmentPolicy` / `serverConfig` | Cached `/config` getters.                                                         |
| `OrigonClient.initLogging(filter:)`                                                                           | Install Rust-side `tracing` subscriber.                                           |

### Types

- `ClientConfig` — endpoint, token, userId, platform, attributes (`[String: Any]?`). The bundle identifier is resolved automatically from `Bundle.main.bundleIdentifier` and sent as `X-Bundle-Id` on every HTTPS call.
- `Channel` — `.chat`, `.voice`.
- `SessionControl` — `.ai`, `.user`.
- `MessageRole` — `.ai`, `.external`, `.user`, `.system`.
- `MessageStatus` — `.sending`, `.delivered`, `.failed`.
- `MessageState` — `.streaming`, `.completed`.
- `Platform` — `.mobile`, `.web`, `.none`.
- `StartSessionOptions` — channel, optional sessionId, optional `data` (raw JSON).
- `StartSessionResponse` — sessionId, url, token.
- `JoinSessionInput` — channel, sessionId, url, token.
- `ActiveSession` — sessionId, channel.
- `AttachmentRule` / `AttachmentPolicy` — tenant policy for attachments.
- `ServerConfig` — full `/config` snapshot.
- `DisconnectReason` — structured disconnect reasons (incl. `.serverClosed(code:detail:)`).
- `ClientEvent` — `.messageAdded`, `.messageUpdated`, `.connected`, `.reconnecting`, `.reconnected`, `.peerAttached`, `.peerDetached`, `.disconnected`, `.callError`, `.controlUpdated`, `.typing`, `.sessionUpdated`. Every case carries `sessionId`.
- `Message` — typed transcript line. Carries `id`, `localId`, `role`, `text`, `html`, `userId`, `userName`, `timestamp`, `attachments`, `errorText`, `status`, `state`.
- `Attachment`, `Contact`, `SessionSummary`, `SessionHistory` — typed shapes returned by `getSessions()` / `getSession(id:)`.
- `SendMessagePayload` — `text`, `html`, `attachments` (input shape for `sendMessage(id:payload:)`).
- `OrigonError` — structured error with `kind`, `statusCode`, `code`, `message`.

Attachment uploads (`upload_attachment` etc.) are not yet wired
through the SDK; the `attachments` field on `SendMessagePayload` is
reserved for that future surface.

## License

Proprietary. All rights reserved.
