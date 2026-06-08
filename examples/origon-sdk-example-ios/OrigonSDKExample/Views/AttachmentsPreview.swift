import SwiftUI
import AVKit
import PDFKit
import OrigonSDK

// Fullscreen paginated preview for a message's attachments. Mirrors the
// web AttachmentsPreview.svelte: image / video / audio / PDF / unsupported
// views, horizontal pagination, filename + counter header, download action.

struct AttachmentsPreview: View {
    let attachments: [Attachment]
    let activeIndex: Int
    @Binding var isPresented: Bool

    @State private var currentIndex: Int = 0

    // Photos-style interactive dismiss + chrome toggle state.
    @State private var dragOffset: CGSize = .zero
    @State private var chromeVisible = false

    // How far (points) a vertical drag travels before the background fully fades.
    private let dismissTravel: CGFloat = 250

    // 0 → at rest, 1 → fully dragged. Drives background fade + content scale.
    private var dragProgress: Double {
        Double(min(1, abs(dragOffset.height) / dismissTravel))
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - dragProgress * 0.7)
                .ignoresSafeArea()

            if attachments.indices.contains(currentIndex) {
                content(for: attachments[currentIndex])
                    .id(currentIndex)
                    .scaleEffect(CGFloat(1 - dragProgress * 0.18))
                    .offset(dragOffset)
                    .transition(.opacity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            chromeVisible.toggle()
                        }
                    }
                    .simultaneousGesture(dismissGesture)
            }

            VStack {
                header
                Spacer()
                if attachments.count > 1 {
                    pagingControls
                        .padding(.bottom, 24)
                }
            }
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible)
            .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        }
        .onAppear { currentIndex = activeIndex }
        .statusBar(hidden: true)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Only treat predominantly vertical drags as a dismiss; this
                // keeps horizontal interactions inside content untouched.
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                let dismiss = abs(value.translation.height) > 150
                    || abs(value.predictedEndTranslation.height) > 450
                if dismiss {
                    isPresented = false
                } else {
                    withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.8)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(fileName(for: attachments[safe: currentIndex]))
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)

            if attachments.count > 1 {
                Text("\(currentIndex + 1) / \(attachments.count)")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer()

            if let att = attachments[safe: currentIndex],
               let url = URL(string: att.url) {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.8))
                }
                .accessibilityLabel("Download")
            }

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.8))
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var pagingControls: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentIndex = max(0, currentIndex - 1)
                }
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.white.opacity(currentIndex == 0 ? 0.2 : 0.8))
            }
            .disabled(currentIndex == 0)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentIndex = min(attachments.count - 1, currentIndex + 1)
                }
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.white.opacity(currentIndex == attachments.count - 1 ? 0.2 : 0.8))
            }
            .disabled(currentIndex == attachments.count - 1)
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func content(for attachment: Attachment) -> some View {
        let name = fileName(for: attachment)
        let category = contentCategory(for: attachment)
        let url = URL(string: attachment.url)

        switch category {
        case .image:
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                    case .failure:
                        unsupportedView(name: name, contentType: "image")
                    default:
                        ProgressView().tint(.white)
                    }
                }
                .padding(.horizontal, 16)
            } else {
                unsupportedView(name: name, contentType: "image")
            }
        case .video:
            if let url {
                VideoPlayer(player: AVPlayer(url: url))
            } else {
                unsupportedView(name: name, contentType: "video")
            }
        case .audio:
            VStack(spacing: 20) {
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 96, height: 96)
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.5))
                    )
                Text(name)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.85))
                if let url {
                    AudioPlayerView(url: url).frame(width: 320)
                }
            }
        case .pdf:
            if let url {
                PDFPreview(url: url)
            } else {
                unsupportedView(name: name, contentType: "pdf")
            }
        case .unsupported:
            unsupportedView(name: name, contentType: "file")
        }
    }

    private func unsupportedView(name: String, contentType: String) -> some View {
        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.1))
                .frame(width: 96, height: 96)
                .overlay(
                    Image(systemName: "doc")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(0.5))
                )
            Text(name)
                .font(.headline)
                .foregroundColor(.white)
            Text(contentType)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
        }
    }

    private func fileName(for attachment: Attachment?) -> String {
        attachment?.name ?? ""
    }

    private enum Category { case image, video, audio, pdf, unsupported }

    private func contentCategory(for attachment: Attachment) -> Category {
        let t = attachment.contentType.lowercased()
        if t.hasPrefix("image/") { return .image }
        if t.hasPrefix("video/") { return .video }
        if t.hasPrefix("audio/") { return .audio }
        if t == "application/pdf" { return .pdf }
        return .unsupported
    }
}

// MARK: - Audio player

private struct AudioPlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.showsPlaybackControls = true
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_: AVPlayerViewController, context: Context) {}
}

// MARK: - PDF preview

private struct PDFPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdf = PDFView()
        pdf.autoScales = true
        pdf.backgroundColor = .black
        pdf.document = PDFDocument(url: url)
        return pdf
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document == nil {
            view.document = PDFDocument(url: url)
        }
    }
}

// MARK: - Helpers

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
