import SwiftUI

// SwiftUI port of the web CallPreview component (web-chat/src/lib/ui/components/CallPreview.svelte).
// Visual states: loading → connected (with delayed Start Talking) → error.
// The `connected` entry choreographs: backdrop "grow", inner scale ring with a
// continuous slow rotation, the gradient logo "appearing" from blur, and the
// mute/end buttons easing from a dim resting state to full opacity.
// Audio-level reactive scaling (web) is intentionally omitted for now.

struct CallView: View {
    var onClose: () -> Void = {}

    @EnvironmentObject var sdk: SDKManager

    // Call-duration timer. Replaces the web's transient "Start Talking" hint:
    // appears 1s after `connected` and ticks every second while the call is up.
    @State private var elapsedSeconds: Int = 0
    @State private var showCallTimer = false
    @State private var callTimerTask: Task<Void, Never>?

    // Resting → animated targets for the call-control buttons. Driven once
    // when entering `connected`, with the same staggered delays as the web.
    @State private var animateMuteButton = false
    @State private var animateSpeakerButton = false
    @State private var animateEndButton = false

    // Approximation of the web's `linear(...)` keyframe easing for `animate-*`
    // (logo appear, inner ring scale, mute/end button reveal). The original is
    // an underdamped-spring shape (~16% overshoot near 26% of the duration,
    // small undershoot, brief ripple, then settles). A SwiftUI spring with
    // response 0.7 / damping 0.5 reproduces that profile far more faithfully
    // than a plain ease-out-back cubic-bezier.
    private static let bounceSpring: Animation =
        .spring(response: 0.7, dampingFraction: 0.5)

    // Treat any non-connected, non-reconnecting phase as "loading" for
    // backdrop choice. Idle is brief — appears between .onAppear firing
    // and startCall returning .connecting.
    private var isLoadingPhase: Bool {
        switch sdk.call.phase {
        case .idle, .connecting: return true
        default: return false
        }
    }

    private var isConnectedPhase: Bool {
        sdk.call.phase == .connected
    }

    var body: some View {
        ZStack {
            Origon.screenBackground.ignoresSafeArea()
            content
        }
        .onAppear {
            Task { try? await sdk.call.startCall() }
        }
        .onChange(of: sdk.call.phase) { newPhase in
            handlePhaseChange(newPhase)
        }
    }

    // MARK: - Layout

    private var content: some View {
        ZStack {
            // Logo cluster: centered, biased upward by the web's `pb-32`.
            logoCluster
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 128)

            // Call-duration timer — appears 1s after `connected`, ticks every
            // second. Sits in the same slot the web uses for "Start Talking".
            if showCallTimer && isConnectedPhase {
                Text(formattedDuration(elapsedSeconds))
                    .font(.title3)
                    .monospacedDigit()
                    .foregroundColor(Origon.textPrimary.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 260)
                    .transition(
                        .scale(scale: 0.9, anchor: .center)
                            .combined(with: .opacity)
                    )
            }

            // Error message row.
            if let errorMessage = errorMessage {
                HStack(spacing: 8) {
                    Image("ErrorIcon")
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(errorMessage)
                        .font(.system(size: 14))
                }
                .foregroundColor(Color.red.opacity(0.8))
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 200)
                .transition(.opacity)
            }

            // Bottom controls.
            HStack(spacing: 32) {
                muteButton
                speakerButton
                endCallButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 80)
        }
        .padding(.horizontal, 8)
        .padding(.top, 52)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.55, dampingFraction: 0.7), value: showCallTimer)
        .animation(.easeInOut(duration: 0.3), value: errorMessage)
        .onDisappear { cancelCallTimer() }
    }

    /// Soft-error from `.callError`, or the disconnect reason text from
    /// `.ended(reason)`. `.ended(nil)` means user-initiated end and shows
    /// no message.
    private var errorMessage: String? {
        if case .ended(let reason) = sdk.call.phase {
            return reason
        }
        return sdk.call.lastError
    }

    // MARK: - Logo cluster

    private var logoCluster: some View {
        ZStack {
            // 240×240 backdrop blur. One of two views depending on phase, so
            // each owns its own self-contained animation lifecycle.
            Group {
                if isLoadingPhase {
                    LoadingBackdrop()
                        .transition(.opacity)
                } else {
                    ConnectedBackdrop()
                        .transition(.opacity)
                }
            }

            // Inner scale ring (224×224, blur 25). Only visible while connected.
            if isConnectedPhase {
                InnerScaleRing()
                    .transition(.opacity)
            }

            // Gradient logo (80×80). Appears from blur on connected.
            ConnectedLogo(visible: isConnectedPhase || isErrorOrEnded)
        }
        .frame(width: 240, height: 240)
        .animation(.easeInOut(duration: 0.3), value: sdk.call.phase)
    }

    private var isErrorOrEnded: Bool {
        if case .ended = sdk.call.phase { return true }
        return false
    }

    // MARK: - Buttons

    private var muteButton: some View {
        Button {
            let next = !sdk.call.muted
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                sdk.call.setMute(next)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(sdk.call.muted ? Color.red : Origon.textPrimary.opacity(0.2))
                Image(sdk.call.muted ? "MicMutedIcon" : "MicIcon")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundColor(sdk.call.muted ? .white : Origon.textPrimary.opacity(0.7))
            }
            .frame(width: 48, height: 48)
            .scaleEffect(animateMuteButton ? 1.12 : 1.0)
            .opacity(animateMuteButton ? 1.0 : 0.5)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(sdk.call.muted ? "Unmute" : "Mute")
    }

    private var speakerButton: some View {
        Button {
            let next = !sdk.call.speakerOn
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                sdk.call.setSpeaker(next)
            }
        } label: {
            ZStack {
                Circle()
                    .fill(sdk.call.speakerOn ? Origon.accent : Origon.textPrimary.opacity(0.2))
                Image(systemName: sdk.call.speakerOn ? "speaker.wave.2.fill" : "speaker.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
                    .foregroundColor(sdk.call.speakerOn ? .white : Origon.textPrimary.opacity(0.7))
            }
            .frame(width: 48, height: 48)
            .scaleEffect(animateSpeakerButton ? 1.12 : 1.0)
            .opacity(animateSpeakerButton ? 1.0 : 0.5)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(sdk.call.speakerOn ? "Turn off speaker" : "Turn on speaker")
    }

    private var endCallButton: some View {
        Button {
            sdk.call.endCall()
            onClose()
        } label: {
            ZStack {
                Circle().fill(Color.red)
                Image("CrossSmallIcon")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .foregroundColor(.white)
            }
            .frame(width: 48, height: 48)
            .scaleEffect(animateEndButton ? 1.12 : 1.0)
            .opacity(animateEndButton ? 1.0 : 0.5)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel("End call")
    }

    // MARK: - Phase-driven animation entry points

    private func handlePhaseChange(_ phase: CallService.Phase) {
        switch phase {
        case .connected:
            // Stagger button reveal + start the call-duration timer, mirroring
            // the original `enterConnected` choreography.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(Self.bounceSpring) { animateMuteButton = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.225) {
                withAnimation(Self.bounceSpring) { animateSpeakerButton = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(Self.bounceSpring) { animateEndButton = true }
            }
            startCallTimer()

        case .ended(let reason):
            cancelCallTimer()
            // Clean local close → dismiss; otherwise leave the error visible
            // and let the user tap End to dismiss.
            if reason == nil {
                onClose()
            }

        case .reconnecting:
            cancelCallTimer()

        case .idle, .connecting:
            animateMuteButton = false
            animateSpeakerButton = false
            animateEndButton = false
            cancelCallTimer()
        }
    }

    // MARK: - Call duration timer

    private func startCallTimer() {
        cancelCallTimer()
        elapsedSeconds = 0
        showCallTimer = false

        callTimerTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, isConnectedPhase else { return }
            elapsedSeconds = 1
            showCallTimer = true

            while !Task.isCancelled, isConnectedPhase {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, isConnectedPhase else { return }
                elapsedSeconds += 1
            }
        }
    }

    private func cancelCallTimer() {
        callTimerTask?.cancel()
        callTimerTask = nil
        showCallTimer = false
        elapsedSeconds = 0
    }

    // Adaptive duration label: seconds-only under a minute, m+s under an hour,
    // and h+m once the call rolls past an hour (seconds dropped — at that scale
    // the second-by-second tick is noise).
    private func formattedDuration(_ totalSeconds: Int) -> String {
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        if totalSeconds < 3600 {
            let m = totalSeconds / 60
            let s = totalSeconds % 60
            return "\(m)m \(s)s"
        }
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        return "\(h)h \(m)m"
    }
}

// MARK: - Backdrop / ring / logo subviews
//
// Each owns its own state so SwiftUI can re-create them when the parent flips
// `phase`, naturally restarting the per-view animation from rest. This mirrors
// how the CSS keyframes restart when the `animate-*` class swaps in.

private struct LoadingBackdrop: View {
    @State private var rotation: Double = 0
    @State private var pulseUp = false

    var body: some View {
        Circle()
            .fill(origonMainGradient)
            .frame(width: 240, height: 240)
            .scaleEffect(pulseUp ? 1.1 : 1.0)
            .opacity(pulseUp ? 0.15 : 0.10)
            .rotationEffect(.degrees(rotation))
            .blur(radius: 40)
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
                withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                    pulseUp = true
                }
            }
    }
}

private struct ConnectedBackdrop: View {
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(origonMainGradient)
            .frame(width: 240, height: 240)
            .scaleEffect(animate ? 5 : 1)
            .opacity(animate ? 0.05 : 0.20)
            .blur(radius: 40)
            .onAppear {
                withAnimation(.timingCurve(0.175, 0.885, 0.32, 1.275, duration: 2)) {
                    animate = true
                }
            }
    }
}

private struct InnerScaleRing: View {
    @State private var scale: CGFloat = 0
    @State private var opacity: Double = 0
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .fill(origonMainGradient)
            .frame(width: 224, height: 224)
            .scaleEffect(scale)
            .opacity(opacity)
            .rotationEffect(.degrees(rotation))
            .blur(radius: 25)
            .onAppear {
                withAnimation(.spring(response: 0.7, dampingFraction: 0.5)) {
                    scale = 1
                    opacity = 0.2
                }
                withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

private struct ConnectedLogo: View {
    let visible: Bool

    @State private var animate = false

    var body: some View {
        Image("OrigonLogo")
            .renderingMode(.original)
            .resizable()
            .frame(width: 72, height: 72)
            .scaleEffect(animate ? 1 : 0)
            .opacity(animate ? 1 : 0)
            .blur(radius: animate ? 0 : 20)
            .onChange(of: visible) { newValue in
                guard newValue else { return }
                withAnimation(.spring(response: 0.7, dampingFraction: 0.5)) {
                    animate = true
                }
            }
    }
}

// MARK: - Origon brand gradient
//
// Conic gradient mapped from the web's `.origon-main-gradient` CSS. CSS
// conic-gradient measures angles clockwise from 12 o'clock; SwiftUI's
// AngularGradient measures from 3 o'clock — hence the −90° offset on the
// start angle. Center offset matches the slight bias used in the web.

private let origonMainGradient = AngularGradient(
    gradient: Gradient(stops: [
        .init(color: Color(rgb: 0x0092FF), location: 0.0),
        .init(color: Color(rgb: 0xFD9700), location: 32.4 / 360),
        .init(color: Color(rgb: 0xFF4400), location: 100.8 / 360),
        .init(color: Color(rgb: 0xFF2469), location: 176.4 / 360),
        .init(color: Color(rgb: 0xC65CFF), location: 280.8 / 360),
        .init(color: Color(rgb: 0x0092FF), location: 1.0),
    ]),
    center: UnitPoint(x: 0.5132, y: 0.5168),
    startAngle: .degrees(56.48),
    endAngle: .degrees(416.48)
)

private extension Color {
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
