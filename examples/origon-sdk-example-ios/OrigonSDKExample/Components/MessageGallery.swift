import SwiftUI
import OrigonSDK

/// Horizontal card carousel under a flow-authored Gallery prompt.
///
/// Cards and their buttons are keyed by **index** throughout: titles and
/// button values may legitimately repeat across cards, which is exactly why
/// a gallery reply carries the card title alongside the value.
struct MessageGallery: View {
    let cards: [MessageCard]
    let isLive: Bool
    /// The picked option — `cardIndex` is nil when it came from a restored
    /// transcript, which cannot say which card it was.
    let selection: ChatService.PromptSelection?
    /// `(cardIndex, card, button)`.
    let onTap: (Int, MessageCard, MessageButton) -> Void

    /// A card's fixed width. The CAROUSEL spans the full transcript width;
    /// each card does not — a full-width card shows one at a time and hides
    /// that there are more. This cap keeps the next card peeking, which is
    /// the affordance that says "scrollable".
    private let cardWidth: CGFloat = 280

    /// Tallest natural card height in this row. Every card is then pinned to
    /// it, so a short card doesn't leave its action buttons floating halfway
    /// up beside a taller neighbour — the same thing a CSS grid row does by
    /// stretching its items. Measured, because SwiftUI has no cross-sibling
    /// height negotiation: an `HStack` sizes each child independently.
    @State private var maxCardHeight: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(cards.enumerated()), id: \.offset) { cardIndex, card in
                    cardView(cardIndex: cardIndex, card: card)
                }
            }
        }
        // The CONTAINER is what goes full width, so the row starts at the
        // leading edge and scrolls the whole way across.
        .frame(maxWidth: .infinity)
        .onPreferenceChange(CardHeightKey.self) { maxCardHeight = $0 }
    }

    private func cardView(cardIndex: Int, card: MessageCard) -> some View {
        // spacing 0: the action buttons are full-bleed and carry their own
        // top divider, so any stack spacing would break the seam.
        VStack(alignment: .leading, spacing: 0) {
            // `image` is legitimately nil — the server emits null for a card
            // authored without one. Unwrapping it unconditionally would crash
            // the whole carousel, not just this card.
            if let url = card.image?.url, !url.isEmpty, let parsed = URL(string: url) {
                // No auth header: the server mints a public capability URL for
                // gallery images, and its GET is deliberately tokenless.
                AsyncImage(url: parsed) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder(systemName: "photo")
                    default:
                        placeholder(systemName: nil)
                    }
                }
                .frame(width: cardWidth, height: 150)
                .clipped()
            }

            VStack(alignment: .leading, spacing: 6) {
                if !card.title.isEmpty {
                    Text(card.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Origon.textPrimary)
                }
                if !card.description.isEmpty {
                    Text(card.description)
                        .font(.footnote)
                        .foregroundColor(Origon.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)

            // Collapses to nothing at natural height; once cards are pinned
            // to the row's tallest, this is what sinks the actions to the
            // bottom edge instead of leaving them mid-card.
            Spacer(minLength: 0)

            ForEach(Array(card.buttons.enumerated()), id: \.offset) { _, button in
                CardActionButton(
                    label: button.label,
                    isSelected: isSelected(cardIndex: cardIndex, button: button),
                    isLive: isLive
                ) {
                    onTap(cardIndex, card, button)
                }
            }
        }
        .frame(width: cardWidth, alignment: .leading)
        // Reported BEFORE the height pin below, so this is the card's NATURAL
        // height. Measuring after the pin would just echo the pinned value
        // back and the row could never shrink again.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CardHeightKey.self, value: proxy.size.height)
            }
        )
        .frame(height: maxCardHeight > 0 ? maxCardHeight : nil, alignment: .top)
        // Applied after the pin so the surface fills the stretched card, not
        // just its natural content box.
        .background(Origon.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Origon.border, lineWidth: 1)
        )
    }

    /// A live pick knows its card, so it highlights exactly one option. A
    /// pick recovered from history knows only the caption — so it may match
    /// the same label on more than one card. That over-match is accepted, not
    /// an oversight: the wire carries nothing that could resolve it, because
    /// connect persists neither the chosen value nor the card title.
    private func isSelected(cardIndex: Int, button: MessageButton) -> Bool {
        guard let selection, selection.buttonLabel == button.label else { return false }
        guard let picked = selection.cardIndex else { return true }
        return picked == cardIndex
    }

    private func placeholder(systemName: String?) -> some View {
        ZStack {
            Origon.surface
            if let systemName {
                Image(systemName: systemName)
                    .foregroundColor(Origon.textTertiary)
            }
        }
    }
}

/// A gallery card's action row: full-bleed, separated by a hairline rather
/// than shaped as a pill. Matches the desktop client, where card actions read
/// as rows of the card rather than as free-floating chips.
private struct CardActionButton: View {
    let label: String
    let isSelected: Bool
    let isLive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundColor(isLive || isSelected ? Origon.accent : Origon.textTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(isSelected ? Origon.accent.opacity(0.12) : Color.clear)
                .overlay(
                    Rectangle()
                        .fill(Origon.border)
                        .frame(height: 1),
                    alignment: .top
                )
        }
        .buttonStyle(.plain)
        .disabled(!isLive)
    }
}

/// Collects the tallest natural card height in a row. `reduce` takes the max
/// across siblings, which is the whole mechanism: every card then pins to it.
private struct CardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
