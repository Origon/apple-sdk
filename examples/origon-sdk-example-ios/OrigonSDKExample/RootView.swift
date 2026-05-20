import SwiftUI

// Two states: no endpoint configured → EndpointView; endpoint set → RootChatView.
// The endpoint is persisted in UserDefaults so relaunching skips straight to the
// chat surface. "Change Endpoint" in the sidebar clears it and falls back here.

struct RootView: View {
    @EnvironmentObject var sdk: SDKManager
    @State private var endpoint: String? = UserDefaults.standard.string(forKey: StorageKeys.origonEndpoint)

    var body: some View {
        Group {
            if let endpoint, !endpoint.isEmpty {
                RootChatView(
                    endpoint: endpoint,
                    onChangeEndpoint: changeEndpoint
                )
                .appScreen()
            } else {
                NavigationStack {
                    EndpointView(onAuthenticated: handleAuthenticated)
                        .loginScreen()
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: endpoint)
    }

    private func handleAuthenticated(_ url: String) {
        UserDefaults.standard.set(url, forKey: StorageKeys.origonEndpoint)
        endpoint = url
    }

    private func changeEndpoint() {
        sdk.teardown()
        UserDefaults.standard.removeObject(forKey: StorageKeys.origonEndpoint)
        endpoint = nil
    }
}
