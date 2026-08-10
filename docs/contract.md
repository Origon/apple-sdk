# Apple SDK contract

This public repository wraps the native C ABI produced by
`/home/yl/workspace/apps/sdk/session`. Public examples explain usage; this file
registers the cross-repository contracts that must change and validate together.

## Mobile chat continuity and push

- `ClientConfig.installation_id` is supplied by this wrapper as a random,
  persisted app-install UUID. It is excluded from backup/restore and is never
  derived from IDFV or other hardware identity. If `userId` is omitted, the
  wrapper uses the same install-scoped value only as an anonymous opaque user id;
  it is not a person identity.
- The C ABI is consumed as one hardcut: `SessionClientConfig.installation_id`,
  required `SessionSummary.active`, `session_client_restore_active_chats`,
  `session_client_open_chat`, generation-returning
  `session_client_register_push`, and generation-bound
  `session_client_unregister_push`. The producer is
  `workspace/apps/sdk/session/include/session_bridge.h`; reciprocal producer
  registration is in `workspace/apps/sdk/CONTRACT.md` and
  `workspace/apps/sdk/session/docs/contract.md`.
- Passive foreground restore calls `restoreActiveChats()` and never takes over
  another installation. Explicit history navigation and a push tap call
  `openChat(sessionId:takeover:)`; takeover is user intent. The wrapper/core
  manager remains the sole per-session operation owner.
- APNs token callbacks may repeat and the latest successful registration wins.
  The returned opaque endpoint generation is persisted and mirrored into an
  optional App Group store for Notification Service Extensions. Logout uses the
  exact token/provider/environment/generation tuple to unregister and then clears
  local notification authority.
- A notification preview is trusted only when its `endpointGeneration` matches
  the locally persisted generation. A mismatch must use generic content or be
  suppressed. Notification taps open the named chat with takeover enabled.
  Provider invalid-token cleanup and the server's 90-day endpoint TTL are the
  uninstall cleanup path; uninstall cannot send an unregister call.

## Release gate

The XCFramework is a local artifact until an owner publishes it. Before any
release, all Apple slices must expose the complete current C ABI, Swift wrapper
tests/typechecking and the example must pass against that artifact, and the
workspace/app consumers must be validated in canonical dependency order. Never
update `Package.swift` to a public binary or publish a release as part of an
implementation spin.
