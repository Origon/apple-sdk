# OrigonSDK iOS Example

A minimal iOS app demonstrating how to integrate **OrigonSDK** for chat and
voice calls. Two screens:

1. **Endpoint** — user enters an endpoint URL; the app calls
   `SDKManager.initialize(endpoint:)` and persists the URL for next launch.
2. **Home** — chat surface with a side drawer that lists past sessions
   (`sdk.getSessions()`), a "New" button, and a voice button that initiates
   a call (`CallService.startCall()`).

## Requirements

- Xcode 15+
- iOS 16+ target device or simulator
- [xcodegen](https://github.com/yonki/XcodeGen) (`brew install xcodegen`)
- A valid Apple Developer team for signing (configure once in Xcode)

## Getting started

```bash
cd apple-sdk/examples/origon-sdk-example-ios
./run.sh
```

`run.sh` runs `xcodegen` and opens the generated project in Xcode. From there:

1. Select a development team under **Signing & Capabilities**.
2. Pick a destination (simulator or device).
3. Hit ⌘R.

On first launch the app shows the Endpoint screen. Enter your Origon endpoint
URL (e.g. `https://api.example.com`) and continue — the app stays signed in
to that endpoint across relaunches. To switch endpoints, open the sidebar →
**Options → Change Endpoint**.

## Where to look in the code

If you want to wire OrigonSDK into your own app, start with these files:

| File | Role |
| --- | --- |
| `Services/SDKManager.swift` | Single entry point. Owns `OrigonClient`, drains the SDK event stream, and exposes `CallService` / `ChatService` to the UI. |
| `Services/ChatService.swift` | Chat state machine — `openSession`, `sendMessage`, attachment upload, typing, multi-session bookkeeping. |
| `Services/CallService.swift` | Voice-call state machine — `startCall`, `setMute`, `endCall`, phase transitions. |
| `Views/EndpointView.swift` | Calls `sdk.initialize(endpoint:)`. |
| `Views/RootChatView.swift` | Boots the SDK, lists sessions, hosts ChatView + CallView. |
| `Views/ChatView.swift` | Composes messages, drives upload UI, kicks off calls. |
| `Views/CallView.swift` | Active-call surface (logo, mute, end). |

## Project layout

```
origon-sdk-example-ios/
├── README.md
├── run.sh
├── project.yml          # xcodegen spec — produces OrigonSDKExample.xcodeproj
└── OrigonSDKExample/
    ├── OrigonSDKExampleApp.swift
    ├── RootView.swift
    ├── Theme.swift
    ├── Constants.swift
    ├── Models.swift
    ├── Assets.xcassets/
    ├── Components/
    ├── Services/
    └── Views/
```

## Permissions

The app requests:
- **Microphone** — for voice calls
- **Camera** — for attaching photos taken in-app

Both usage descriptions are configured in `project.yml`. Photo library access
goes through `PHPickerViewController` and does not require a usage string.

## SDK version

The `OrigonSDK` Swift package is consumed via SPM from
[github.com/Origon/apple-sdk](https://github.com/Origon/apple-sdk). The
pinned version lives in `project.yml` under `packages.OrigonSDK.exactVersion`.
Bump it when you want to test a newer SDK release.
