import SwiftUI

// Three app-wide button variants. All share the same 48pt height, pill
// cornerRadius, and a uniform press-scale effect.
//
//  • PrimaryButton   — brand accent fill (orange), white foreground.
//                      Default "call to action" on most screens.
//  • SecondaryButton — surface fill with optional trailing icon; neutral
//                      alternative that doesn't compete with the primary.
//  • InvertedButton  — label-color fill with background foreground. High
//                      contrast (black-on-white / white-on-black). Used on
//                      login/auth screens where the brand accent hasn't been
//                      introduced yet.

// MARK: - Press scale style

// Shared press-down feedback: scales to 0.95 on press, restores on release.
// Used by all three variants so taps feel consistent across the app.
struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Primary

struct PrimaryButton: View {
    let title: String
    var loading: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    private var isInactive: Bool { loading || disabled }

    var body: some View {
        Button(action: action) {
            Group {
                if loading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.8)
                } else {
                    Text(title)
                        .font(.callout.weight(.medium))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Origon.accent)
            .cornerRadius(50)
            .opacity(isInactive ? 0.5 : 1)
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(isInactive)
    }
}

// MARK: - Inverted

struct InvertedButton: View {
    let title: String
    var loading: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    private var isInactive: Bool { loading || disabled }

    var body: some View {
        Button(action: action) {
            Group {
                if loading {
                    ProgressView()
                        .tint(Origon.background)
                        .scaleEffect(0.8)
                } else {
                    Text(title)
                        .font(.callout.weight(.medium))
                }
            }
            .foregroundColor(Origon.background)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Origon.textPrimary)
            .cornerRadius(50)
            .opacity(isInactive ? 0.5 : 1)
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(isInactive)
    }
}

// MARK: - Secondary

struct SecondaryButton: View {
    let title: String
    let icon: String
    var loading: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    private var isInactive: Bool { loading || disabled }

    var body: some View {
        Button(action: action) {
            ZStack {
                if loading {
                    ProgressView()
                        .tint(Origon.textPrimary)
                        .scaleEffect(0.8)
                } else {
                    Text(title)
                        .font(.callout.weight(.medium))
                }

                HStack {
                    Spacer()
                    buttonIcon(icon)
                }
            }
            .foregroundColor(Origon.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .padding(.horizontal, 16)
            .background(Origon.surface)
            .cornerRadius(50)
            .opacity(isInactive ? 0.5 : 1)
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(isInactive)
    }
}

// Render a button icon from either an SF Symbol (names containing ".")
// or an asset catalog image (rendered as a template so `.foregroundColor`
// applies). Template rendering also preserves any alpha from the SVG.
@ViewBuilder
private func buttonIcon(_ name: String) -> some View {
    if name.contains(".") {
        Image(systemName: name)
            .font(.body)
            .foregroundColor(Origon.textTertiary)
    } else {
        Image(name)
            .renderingMode(.template)
            .foregroundColor(Origon.textPrimary)
    }
}
