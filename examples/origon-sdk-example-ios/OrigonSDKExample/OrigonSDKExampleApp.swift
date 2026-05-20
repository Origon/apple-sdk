import SwiftUI
import OrigonSDK

@main
struct OrigonSDKExampleApp: App {
    @StateObject private var sdk = SDKManager()

    init() {
        OrigonClient.initLogging(filter: "info,session=debug,moq=debug")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sdk)
        }
    }
}
