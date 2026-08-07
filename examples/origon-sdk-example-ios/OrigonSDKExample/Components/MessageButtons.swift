import SwiftUI
import OrigonSDK

/// The option row under a flow-authored Button prompt.
///
/// Options are keyed by **index**, never by label or value: a flow author is
/// free to repeat either, and duplicate keys in a `ForEach` are a correctness
/// bug, not a style one.
struct MessageButtons: View {
    let buttons: [MessageButton]
    /// `false` once the prompt has been answered or the session ended — the
    /// pills stay visible (they are part of the transcript) but stop
    /// responding, so the user can still read what was offered.
    let isLive: Bool
    /// The option the user picked, if any. Matched on the caption because
    /// that is all a restored transcript can offer.
    let selectedLabel: String?
    let onTap: (MessageButton) -> Void

    var body: some View {
        PromptFlowLayout(spacing: 8) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                PromptPill(
                    label: button.label,
                    isSelected: selectedLabel == button.label,
                    isLive: isLive
                ) {
                    onTap(button)
                }
            }
        }
    }
}

/// One tappable option. Shared by the button row and each gallery card's
/// own stack so the two cannot drift apart visually.
struct PromptPill: View {
    let label: String
    let isSelected: Bool
    let isLive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundColor(foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(isSelected ? Origon.accent : Color.clear)
                )
                .overlay(
                    Capsule().stroke(
                        isSelected ? Origon.accent : Origon.border,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(!isLive)
        // A picked option stays fully legible after the prompt closes; the
        // ones NOT picked fade, so a glance at old history shows what was
        // chosen without re-reading every label.
        .opacity(isLive || isSelected ? 1 : 0.5)
    }

    private var foreground: Color {
        if isSelected { return Origon.accentForeground }
        return isLive ? Origon.accent : Origon.textTertiary
    }
}

/// Wrapping row layout — SwiftUI ships no wrapping stack, and a prompt's
/// options are author-written text of unpredictable width, so a plain
/// `HStack` would push them off-screen.
struct PromptFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height } +
            spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = layout(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = subviews[item].sizeThatFits(.unspecified)
                subviews[item].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty, needed > maxWidth {
                rows.append(current)
                current = Row()
                current.items = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.items.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
