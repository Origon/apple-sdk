import SwiftUI

// Shared single-line input for auth surfaces (LoginView, EmailSignInView,
// EndpointView). Wraps a styled TextField and handles the error UX in one
// place: when `errorMessage` transitions non-nil the field shakes, shows a
// red border, fires an error haptic, and surfaces an inline caption below.
//
// Parents clear the error by setting `errorMessage = nil`, typically on
// the next submit attempt or on text change.
struct OrigonInput: View {
    let placeholder: String
    @Binding var text: String
    var errorMessage: String?
    var keyboardType: UIKeyboardType = .default
    var contentType: UITextContentType? = nil
    var focus: FocusState<Bool>.Binding? = nil

    @State private var shakeCounter: Int = 0

    private var isError: Bool { errorMessage != nil }

    var body: some View {
        VStack(spacing: 8) {
            field
                .modifier(ShakeEffect(animatableData: CGFloat(shakeCounter)))

            if let errorMessage {
                // Server errors can be arbitrarily long — cap at two lines so
                // the caption never pushes the layout around.
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(Origon.error)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.linear(duration: 0.55), value: shakeCounter)
        .animation(.easeInOut(duration: 0.2), value: errorMessage)
        .onChange(of: errorMessage) { newValue in
            guard newValue != nil else { return }
            shakeCounter += 1
            Haptics.error()
        }
    }

    @ViewBuilder
    private var field: some View {
        if let focus {
            styledField.focused(focus)
        } else {
            styledField
        }
    }

    private var styledField: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.body)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Origon.surface)
            .cornerRadius(50)
            .overlay(
                RoundedRectangle(cornerRadius: 50)
                    .stroke(Origon.error, lineWidth: 1.5)
                    .opacity(isError ? 1 : 0)
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(keyboardType)
            .textContentType(contentType)
    }
}
