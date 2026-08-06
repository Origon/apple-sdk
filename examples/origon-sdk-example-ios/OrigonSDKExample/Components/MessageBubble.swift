import SwiftUI
import OrigonSDK

struct MessageBubble: View {
    let message: Message
    @Binding var selectedIndex: Int?
    let index: Int

    @State private var previewOpen = false
    @State private var previewIndex = 0

    private var isSelfUser: Bool {
        message.role == .external
    }

    private var showTimestamp: Bool {
        selectedIndex == index && message.timestamp != nil
    }

    var body: some View {
        // A lifecycle system row (action present: queued / joined / ended)
        // renders as a centered divider; a `.system` row WITHOUT an action is
        // a connect flow-bot message and keeps bubble rendering. The
        // discriminator is **action-presence, not role** — branching on
        // `role == .system` would silently swallow every flow-bot message.
        // Vocabulary is connect's; see `Message.action` in the SDK.
        if let action = message.action, !action.isEmpty {
            systemDivider
        } else {
            bubbleBody
        }
    }

    /// Centered divider for a lifecycle system row. The label is connect's
    /// server-formatted `text` — "Bo has joined", "Conversation has ended",
    /// "You're in <queue> queue" — rendered VERBATIM. connect owns the
    /// phrasing and pins the actor into `text`, and passes `userId`/`userName`
    /// as EMPTY strings for `queued`/`ended`, so a client that composed its own
    /// wording from `userName` would render nothing at all.
    private var systemDivider: some View {
        HStack(spacing: 10) {
            dividerLine
            Text(message.text ?? "")
                .font(.caption)
                .foregroundColor(Origon.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            dividerLine
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(Origon.border)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private var bubbleBody: some View {
        HStack {
            if isSelfUser { Spacer(minLength: 60) }

            VStack(alignment: isSelfUser ? .trailing : .leading, spacing: 6) {
                if let text = message.text, !text.isEmpty {
                    Text(text)
                        .font(.body)
                        .foregroundColor(isSelfUser ? Origon.accentForeground : Origon.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            BubbleShape()
                                .fill(isSelfUser ? Origon.accent : Origon.peerBubble)
                        )
                }

                if !message.attachments.isEmpty {
                    VStack(alignment: isSelfUser ? .trailing : .leading, spacing: 6) {
                        ForEach(Array(message.attachments.enumerated()), id: \.offset) { idx, att in
                            AttachmentRow(attachment: att, isSelfUser: isSelfUser)
                                .onTapGesture {
                                    previewIndex = idx
                                    previewOpen = true
                                }
                        }
                    }
                }

                if message.status == .failed {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text(message.errorText?.isEmpty == false
                             ? message.errorText!
                             : "Failed to send")
                            .font(.caption2)
                    }
                    .foregroundColor(Origon.error)
                    .padding(.horizontal, 4)
                }

                if showTimestamp, message.status != .sending,
                   let timestamp = message.timestamp
                {
                    Text(formatTimestamp(timestamp))
                        .font(.caption2)
                        .foregroundColor(Origon.textTertiary)
                        .padding(.horizontal, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            if !isSelfUser { Spacer(minLength: 60) }
        }
        .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedIndex = selectedIndex == index ? nil : index
            }
        }
        .fullScreenCover(isPresented: $previewOpen) {
            AttachmentsPreview(
                attachments: message.attachments,
                activeIndex: previewIndex,
                isPresented: $previewOpen
            )
        }
    }

    private func formatTimestamp(_ iso8601: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        guard let date = formatter.date(from: iso8601) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: iso8601)
        }() else {
            return ""
        }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        return timeFormatter.string(from: date)
    }
}

// MARK: - Attachment row
//
// Matches the web MessageItem layout: a 44pt-tall rounded capsule with an
// image thumbnail or file icon on the left, the filename, and a download
// button on the right.

private struct AttachmentRow: View {
    let attachment: Attachment
    let isSelfUser: Bool

    private var fileName: String { attachment.name }
    private var contentType: String { attachment.contentType }

    var body: some View {
        HStack(spacing: 10) {
            if contentType.hasPrefix("image/"), let url = URL(string: attachment.url) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.12))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: iconName(for: contentType))
                            .font(.system(size: 14))
                            .foregroundColor(isSelfUser ? Origon.accentForeground : Origon.textSecondary)
                    )
            }

            Text(fileName)
                .font(.subheadline)
                .foregroundColor(isSelfUser ? Origon.accentForeground : Origon.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Button {
                download()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelfUser ? Origon.accentForeground : Origon.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minWidth: 180, maxWidth: 280, minHeight: 44)
        .background(isSelfUser ? Origon.accent : Origon.peerBubble)
        .cornerRadius(10)
    }

    private func iconName(for contentType: String) -> String {
        let t = contentType.lowercased()
        switch true {
        case t == "application/pdf": return "doc.richtext"
        case t.hasPrefix("audio/"): return "waveform"
        case t.hasPrefix("video/"): return "play.rectangle"
        case t.contains("zip"): return "doc.zipper"
        default: return "doc"
        }
    }

    private func download() {
        guard let url = URL(string: attachment.url) else { return }
        UIApplication.shared.open(url)
    }
}

private struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.height / 2, 22)
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
    }
}
