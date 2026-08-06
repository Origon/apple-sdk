import SwiftUI

enum Origon {
    // Accent — adaptive monochrome: black in light mode, white in dark mode.
    // Text/content on top of `accent` should use `accentForeground` (the
    // inverse), NOT a fixed white.
    static let accent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white : UIColor.black
    })
    // Foreground for content sitting on top of `accent`: white in light mode
    // (on black), dark in dark mode (on white).
    static let accentForeground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0x11 / 255, alpha: 1)
            : UIColor.white
    })

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
    // Peer (agent) message bubble: black @ 6% in light mode, white @ 6% in
    // dark mode. Subtle tint rather than the brand accent, so text on top uses
    // the adaptive `textPrimary` (not white). The self bubble uses the brand
    // `accent`; this neutral tint is the incoming/peer side.
    static let peerBubble = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.06)
            : UIColor(white: 0, alpha: 0.06)
    })
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
