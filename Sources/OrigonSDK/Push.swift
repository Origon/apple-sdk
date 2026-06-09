import Foundation
import os

// MARK: - Public push API

extension OrigonClient {
    /// Register this device's APNs token so the backend can deliver push
    /// notifications.
    ///
    /// Call this from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    /// It is safe to call:
    /// - **before `OrigonClient` is initialized** — the token is buffered
    ///   and the registration is sent automatically once a client exists;
    /// - **repeatedly** (e.g. on every APNs token refresh) — the most
    ///   recent token wins.
    ///
    /// The call returns immediately and performs the network request on a
    /// background queue. Failures are logged rather than thrown: APNs
    /// delivers tokens through a fire-and-forget OS callback, so there is
    /// no caller to surface an error to. The SDK re-sends on the next
    /// launch when the app calls this again with the current token.
    ///
    /// - Parameters:
    ///   - deviceToken: the raw token `Data` handed to
    ///     `didRegisterForRemoteNotificationsWithDeviceToken`. The SDK
    ///     hex-encodes it for the wire.
    ///   - environment: APNs environment override. Defaults to `nil`,
    ///     which auto-detects from the embedded provisioning profile
    ///     (and falls back to ``APNSEnvironment/production`` for App Store
    ///     builds, which ship no profile).
    public static func registerForPushNotifications(
        deviceToken: Data,
        environment: APNSEnvironment? = nil
    ) {
        let hexToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        PushRegistrar.shared.register(token: hexToken, environment: environment)
    }

    /// Remove this device's push registration for the current user.
    ///
    /// Clears any token buffered before init so a subsequent
    /// initialization will not re-register. Returns immediately and runs
    /// the network request on a background queue; failures are logged.
    /// Typically called on logout.
    public static func unregisterForPushNotifications() {
        PushRegistrar.shared.unregister()
    }
}

// MARK: - Registrar

/// Process-wide coordinator for push registration.
///
/// Push registration is a device/app-level concern that can race
/// `OrigonClient` initialization (APNs often delivers the token before
/// the app has built its client), so the state lives here rather than on
/// a client instance. A single serial queue owns all mutable state and
/// performs the blocking FFI calls, which keeps registration ordered and
/// off the main thread.
final class PushRegistrar: @unchecked Sendable {
    static let shared = PushRegistrar()

    private let queue = DispatchQueue(label: "ai.origon.sdk.push")
    private let log = Logger(subsystem: "ai.origon.sdk", category: "push")

    // All state below is confined to `queue`.

    /// The most recently initialized client, or `nil` before init / after
    /// it is torn down. Weak so the registrar never keeps a client alive.
    private weak var client: OrigonClient?
    /// Latest token awaiting (re-)send. Retained so a client created after
    /// the token arrives can still register, and so we can resend on a
    /// later attach.
    private var bufferedToken: String?
    private var bufferedEnvironment: APNSEnvironment?

    /// APNs environment for this build. Constant for the process lifetime,
    /// so it is resolved once on first use.
    private lazy var detectedEnvironment: APNSEnvironment = Self.detectEnvironment()

    // MARK: Client lifecycle (called by OrigonClient)

    /// Record the active client and flush any token buffered before init.
    ///
    /// The client is held weakly; its reference auto-nils when the client
    /// deallocates, so there is no explicit detach.
    func attach(_ client: OrigonClient) {
        queue.async {
            self.client = client
            guard let token = self.bufferedToken else { return }
            self.log.debug("flushing buffered push token after init")
            self.sendRegister(client: client, token: token, environment: self.bufferedEnvironment)
        }
    }

    // MARK: Registration (called by the public API)

    func register(token: String, environment: APNSEnvironment?) {
        queue.async {
            let resolved = environment ?? self.detectedEnvironment
            self.bufferedToken = token
            self.bufferedEnvironment = resolved
            guard let client = self.client else {
                self.log.debug("no active client; buffering push token until init")
                return
            }
            self.sendRegister(client: client, token: token, environment: resolved)
        }
    }

    func unregister() {
        queue.async {
            self.bufferedToken = nil
            self.bufferedEnvironment = nil
            guard let client = self.client else {
                self.log.debug("no active client; nothing to unregister")
                return
            }
            do {
                try client.unregisterPush()
            } catch {
                self.log.error("unregisterForPushNotifications failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Must be called on `queue`.
    private func sendRegister(client: OrigonClient, token: String, environment: APNSEnvironment?) {
        do {
            try client.registerPush(token: token, provider: "apns", environment: environment?.rawValue)
        } catch {
            self.log.error("registerForPushNotifications failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: APNs environment detection

    /// Resolve the APNs environment from the app's embedded provisioning
    /// profile.
    ///
    /// The profile (`embedded.mobileprovision`) is a CMS-signed blob with
    /// a plaintext XML plist embedded in it; we slice out the
    /// `<?xml … </plist>` range and read `Entitlements.aps-environment`
    /// (`development` → ``APNSEnvironment/sandbox``, `production` →
    /// ``APNSEnvironment/production``). App Store builds ship no profile,
    /// so a missing file resolves to `.production`.
    private static func detectEnvironment() -> APNSEnvironment {
        guard
            let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url),
            let raw = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .isoLatin1),
            let start = raw.range(of: "<?xml"),
            let end = raw.range(of: "</plist>")
        else {
            return .production
        }
        let plistString = String(raw[start.lowerBound..<end.upperBound])
        guard
            let plistData = plistString.data(using: .isoLatin1),
            let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
            let dict = plist as? [String: Any],
            let entitlements = dict["Entitlements"] as? [String: Any],
            let apsEnvironment = entitlements["aps-environment"] as? String
        else {
            return .production
        }
        return apsEnvironment == "production" ? .production : .sandbox
    }
}
