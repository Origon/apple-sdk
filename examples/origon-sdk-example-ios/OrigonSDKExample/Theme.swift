import SwiftUI

enum Origon {
    static let accent = Color(red: 234 / 255, green: 88 / 255, blue: 12 / 255)

    static let background = Color(.systemBackground)
    static let screenBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 1)
            : UIColor.systemBackground
    })
    static let surface = Color(.secondarySystemBackground)
    static let textPrimary = Color(.label)
    static let textSecondary = Color(.secondaryLabel)
    static let textTertiary = Color(.tertiaryLabel)
    static let userBubble = Color.blue
    static let remoteBubble = Color(.systemGray5)
    static let error = Color.red
    static let border = Color(.separator)

    static let toastBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white
            : UIColor(red: 0x33 / 255, green: 0x33 / 255, blue: 0x33 / 255, alpha: 1)
    })
    static let toastForeground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x33 / 255, green: 0x33 / 255, blue: 0x33 / 255, alpha: 1)
            : UIColor.white
    })
}

extension View {
    func appScreen() -> some View {
        screenBackground(Origon.screenBackground)
    }

    func loginScreen() -> some View {
        screenBackground(Origon.background)
    }

    private func screenBackground(_ color: Color) -> some View {
        ZStack {
            color.ignoresSafeArea()
            self
        }
    }
}
