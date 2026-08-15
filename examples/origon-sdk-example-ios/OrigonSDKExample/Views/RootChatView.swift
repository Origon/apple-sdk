import SwiftUI

// Root view for the logged-in app. Hosts ChatView + a push-and-peek sidebar
// drawer + the call overlay. Boots the SDK from the persisted endpoint on
// first appearance; tearing the endpoint down is handled by the parent
// (RootView) via the `onChangeEndpoint` closure.

struct RootChatView: View {
    let endpoint: String
    let onChangeEndpoint: () -> Void

    @EnvironmentObject var sdk: SDKManager

    @State private var sidebarOpen = false
    @State private var dragOffset: CGFloat = 0
    @State private var sessionId: String? = nil
    @State private var initError: String?
    @State private var isInitializing = false
    @State private var bootTask: Task<Void, Never>?
    @State private var breathing = false
    @State private var isExiting = false
    @State private var isCallActive = false

    private let sidebarWidth: CGFloat = 320

    private var openProgress: CGFloat {
        let base: CGFloat = sidebarOpen ? 1.0 : 0.0
        let dragProgress = dragOffset / sidebarWidth
        return min(max(base + dragProgress, 0), 1)
    }

    var body: some View {
        ZStack {
            Group {
                if isInitializing {
                    loadingState
                } else if let error = initError {
                    errorState(error)
                } else {
                    drawerContainer
                }
            }
            .onAppear { boot() }

            if isCallActive {
                CallView(onClose: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isCallActive = false
                    }
                })
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isCallActive)
    }

    // MARK: - States

    private var loadingState: some View {
        Image("OrigonLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 56, height: 56)
            .scaleEffect(isExiting ? 1.0 : (breathing ? 1.14 : 1.0))
            .opacity(isExiting ? 1.0 : (breathing ? 1.0 : 0.5))
            .animation(
                .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                value: breathing
            )
            .animation(.easeOut(duration: 0.18), value: isExiting)
            .onAppear {
                DispatchQueue.main.async { breathing = true }
            }
            .onDisappear { breathing = false }
            .padding(.bottom, 76)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(Origon.error)
            Text(error)
                .font(.subheadline)
                .foregroundColor(Origon.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            PrimaryButton(title: "Retry") { boot() }
                .padding(.horizontal, 32)
            Button {
                onChangeEndpoint()
            } label: {
                Text("Change Endpoint")
                    .font(.callout.weight(.medium))
                    .foregroundColor(Origon.textSecondary)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drawer composition

    private var drawerContainer: some View {
        ZStack(alignment: .leading) {
            chatLayer
                .offset(x: sidebarWidth * openProgress)
                .edgePanGesture(edge: .left) { state in
                    handleEdgePan(state)
                }

            Color.black.opacity(0.35 * openProgress)
                .ignoresSafeArea()
                .allowsHitTesting(sidebarOpen)
                .gesture(closeDragGesture)

            SidebarView(
                selectedSessionId: $sessionId,
                onSessionPicked: { picked in
                    sessionId = picked
                    closeSidebar()
                },
                onChangeEndpoint: {
                    closeSidebar()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        onChangeEndpoint()
                    }
                }
            )
            .frame(width: sidebarWidth)
            .background(Origon.screenBackground)
            .offset(x: -sidebarWidth * (1 - openProgress))
        }
        .navigationBarBackButtonHidden(true)
    }

    private var chatLayer: some View {
        NavigationStack {
            ChatView(
                sessionId: $sessionId,
                onMenuTap: openSidebar,
                onNewSession: startNewSession,
                onStartCall: startCall
            )
            .appScreen()
        }
    }

    private func startCall() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        isCallActive = true
    }

    // MARK: - Edge pan (open)

    private func handleEdgePan(_ state: EdgePanState) {
        switch state {
        case .changed(let translation):
            if dragOffset == 0, translation > 0 {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
            dragOffset = min(max(translation, 0), sidebarWidth)
        case .ended(let translation, let velocity):
            let projected = translation + velocity * 0.25
            let shouldOpen = projected > sidebarWidth / 2
            withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                dragOffset = 0
                sidebarOpen = shouldOpen
            }
        case .cancelled:
            withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                dragOffset = 0
            }
        }
    }

    // MARK: - Drag gesture (close)

    private var closeDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let translation = min(0, value.translation.width)
                dragOffset = translation
            }
            .onEnded { value in
                if abs(value.translation.width) < 5, abs(value.translation.height) < 5 {
                    closeSidebar()
                    return
                }
                let velocity = value.predictedEndTranslation.width - value.translation.width
                let projected = value.translation.width + velocity * 0.25
                let shouldStayOpen = projected > -(sidebarWidth / 2)
                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                    dragOffset = 0
                    sidebarOpen = shouldStayOpen
                }
            }
    }

    private func openSidebar() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
            sidebarOpen = true
        }
    }

    private func closeSidebar() {
        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
            sidebarOpen = false
        }
    }

    // MARK: - Session lifecycle

    private func startNewSession() {
        sdk.chat.endCurrentSession()
        sessionId = nil
    }

    private func boot() {
        guard !sdk.isReady else {
            Task { try? await sdk.refreshSessions() }
            return
        }

        isInitializing = true
        initError = nil

        bootTask?.cancel()
        bootTask = Task {
            do {
                try await sdk.initialize(endpoint: endpoint)
                try await sdk.refreshSessions()
                await settleBreathingAndExit()
            } catch {
                await settleBreathingAndExit()
                await MainActor.run {
                    initError = "Failed to connect: \(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    private func settleBreathingAndExit() async {
        isExiting = true
        try? await Task.sleep(nanoseconds: 200_000_000)
        isInitializing = false
        isExiting = false
    }
}
