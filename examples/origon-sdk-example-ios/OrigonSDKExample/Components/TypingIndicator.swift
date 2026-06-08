import SwiftUI

struct TypingIndicator: View {
    // Full bounce cycle (up + back down) in seconds.
    private let cycle: Double = 1.0

    var body: some View {
        HStack {
            // Driven by wall-clock time so the animation is deterministic on
            // every render — no @State / onAppear that can fail to re-trigger
            // when the view's identity is reused.
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Origon.textSecondary)
                            .frame(width: 8, height: 8)
                            .offset(y: offset(at: t, index: index))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Origon.remoteBubble)
                .cornerRadius(18)
            }

            Spacer(minLength: 60)
        }
    }

    /// Vertical offset (0 ... -4) for a given dot, evenly phased across the cycle.
    private func offset(at time: Double, index: Int) -> CGFloat {
        let phase = time / cycle - Double(index) / 3.0
        let bounce = (sin(phase * 2 * .pi) + 1) / 2   // 0 ... 1
        return -4 * bounce
    }
}
