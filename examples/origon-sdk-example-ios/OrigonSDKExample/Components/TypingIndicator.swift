import SwiftUI

struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Origon.textSecondary)
                        .frame(width: 8, height: 8)
                        .offset(y: animating ? -4 : 0)
                        .animation(
                            .easeInOut(duration: 0.4)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.15),
                            value: animating
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Origon.remoteBubble)
            .cornerRadius(18)

            Spacer(minLength: 60)
        }
        .onAppear {
            animating = true
        }
    }
}
