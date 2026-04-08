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

// 1. Create the client
let config = ClientConfig(
    endpoint: "https://api.origon.ai",
    token: "your-api-token",
    userId: "user-123"
)
let client = try OrigonClient(config: config)

// 2. Start a session
let session = try client.startSession(
    StartSessionOptions(channel: .chat)
)

// 3. Send a message
let sessionId = try client.sendMessage(
    SendMessagePayload(text: "Hello!")
)

// 4. Poll for events
if let event = client.pollEvent() {
    switch event {
    case .messageAdded(let message, _):
        print("New message: \(message.text ?? "")")
    case .typing(let isTyping):
        print(isTyping ? "Agent is typing..." : "")
    default:
        break
    }
}

// 5. End the session
try client.endSession()
```

### Voice Sessions

```swift
let session = try client.startSession(
    StartSessionOptions(channel: .voice)
)

let isMuted = try client.toggleMute()
```

### Attachments

```swift
let (attachment, progressStream) = try client.uploadAttachment(
    data: imageData,
    filename: "photo.jpg"
)

for await progress in progressStream {
    print("\(progress.percent)% uploaded")
}

try client.sendMessage(
    SendMessagePayload(text: "See attached", attachments: [attachment])
)
```

## API Reference

### OrigonClient

| Method | Description |
|---|---|
| `init(config:)` | Create a client with the given configuration |
| `pollEvent()` | Poll for the next server event (non-blocking) |
| `startSession(_:)` | Start or resume a session |
| `getSessions()` | List all session summaries |
| `getSession(sessionId:)` | Fetch control state and messages for a session |
| `endSession()` | End the current active session |
| `sendMessage(_:)` | Send a message, returns the session ID |
| `uploadAttachment(data:filename:)` | Upload a file, returns info and progress stream |
| `deleteAttachment(mediaId:)` | Delete an uploaded attachment |
| `getAttachmentUrl(mediaId:)` | Get the download URL for an attachment |
| `toggleMute()` | Toggle voice mute, returns new mute state |

### Types

- `ClientConfig` -- endpoint, token, and external ID
- `StartSessionOptions` -- channel, optional session ID, fetch flag
- `SendMessagePayload` -- text, HTML, context, attachments, meta
- `SessionInfo` -- full session with messages, control, config, active state
- `SessionSummary` -- lightweight session listing entry
- `Message` -- a single message with role, content, attachments, tool calls
- `AttachmentInfo` -- media ID and URL for an uploaded file
- `ToolCall` -- tool invocation with ID, name, and arguments
- `UploadProgress` -- percent, loaded bytes, total bytes
- `ClientEvent` -- server-pushed event (message, control, typing, etc.)
- `Channel` -- `.chat` or `.voice`
- `Control` -- `.agent` or `.human`
- `MessageRole` -- `.assistant`, `.user`, `.supervisor`, `.system`, `.tool`

## License

Proprietary. All rights reserved.
