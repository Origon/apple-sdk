import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import OrigonSDK

private struct ExampleTranscriptFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ExampleTranscriptSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct ChatView: View {
    @Binding var sessionId: String?
    let onMenuTap: () -> Void
    let onNewSession: () -> Void
    let onStartCall: () -> Void

    @EnvironmentObject var sdk: SDKManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var inputText = ""
    @State private var hasStartedSession = false
    @State private var hasFocusedOnce = false
    @State private var selectedMessageIndex: Int?
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var isSending = false
    @State private var toastMessage: String?
    @State private var showToast = false
    @State private var checkpointLoaded = false
    @State private var checkpointLastSeenMessageId: String?
    @State private var unreadAnchorMessageId: String?
    @State private var positionedForVisit = false
    @State private var visibleRowIds: [String] = []
    @State private var latestRowVisible = false
    @State private var transcriptSize: CGSize = .zero
    @State private var sendFollowIntent: ExampleTranscriptFollowIntent?
    @State private var lastCheckpointCandidate: String?
    @FocusState private var isInputFocused: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if sdk.chat.messages.isEmpty && !sdk.chat.isTyping {
                    emptyState
                } else {
                    messagesArea
                }
                if sdk.endpointPolicy.showsComposer {
                    inputBar
                } else if sdk.endpointPolicy.showsVoiceOnlyAction {
                    PrimaryButton(title: "Start a call", action: onStartCall)
                        .padding(16)
                } else {
                    Text("Messaging and calls are disabled for this endpoint.")
                        .font(.footnote)
                        .foregroundColor(Origon.textSecondary)
                        .padding(16)
                }
            }

            if showToast, let message = toastMessage {
                VStack {
                    Spacer()
                    Text(message)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Origon.toastForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Origon.toastBackground)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 96)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .zIndex(1)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showToast)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: onMenuTap) {
                    Image("HistoryIcon")
                        .renderingMode(.template)
                        .foregroundColor(Origon.textPrimary)
                }
                .accessibilityLabel("Session history")
            }
            // Only offer "new session" once the current conversation has
            // content. On an empty session, tapping it would just restart the
            // same empty screen — reading as a no-op to the user.
            if !sdk.chat.messages.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: onNewSession) {
                        Image("PlusIcon")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .foregroundColor(Origon.textPrimary)
                    }
                    .accessibilityLabel("New session")
                }
            }
        }
        .onAppear {
            focusSessionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )) { _ in
            sdk.chat.refetchFocusedSession()
        }
        .onChange(of: sessionId) { _ in
            hasStartedSession = false
            hasFocusedOnce = false
            resetTranscriptVisit()
            focusSessionIfNeeded()
        }
        .onChange(of: sdk.chat.currentSessionId) { _ in
            guard !hasFocusedOnce else { return }
            hasFocusedOnce = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isInputFocused = true
            }
        }
        .task(id: checkpointTaskId) {
            await loadCheckpointForVisit()
        }
        .onChange(of: sdk.chat.error) { newValue in
            guard let message = newValue, !message.isEmpty else { return }
            presentToast(message)
            sdk.chat.error = nil
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, latestRowVisible,
                  let id = resolvedCheckpointSessionId else { return }
            Task {
                await sdk.markCheckpointSeen(
                    sessionId: id, latestRowVisible: true, sceneForeground: true
                )
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoSelections,
            maxSelectionCount: nil,
            matching: photoPickerFilter
        )
        .onChange(of: photoSelections) { items in
            guard !items.isEmpty else { return }
            handlePhotoSelections(items)
            photoSelections = []
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPickerView(
                onImageCaptured: { image in
                    handleCapturedImage(image)
                    showCamera = false
                },
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()
            Image("OrigonLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
            Text(sdk.endpointPolicy.greeting)
                .font(.title2.weight(.medium))
                .foregroundColor(Origon.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onTapGesture { isInputFocused = false }
    }

    // MARK: - Sub-views

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(transcriptRows) { row in
                        if row.message.id == unreadAnchorMessageId {
                            newMessagesDivider
                        }
                        MessageBubble(
                            message: row.message,
                            selectedIndex: $selectedMessageIndex,
                            index: row.index,
                            showsAuthor: exampleShouldShowAuthor(
                                row.message,
                                previous: row.index > 0 ? sdk.chat.messages[row.index - 1] : nil
                            ),
                            promptIsLive: sdk.endpointPolicy.promptSendEnabled &&
                                sdk.chat.promptIsLive(row.message, in: sdk.chat.currentSessionId),
                            promptSelection: sdk.chat.selection(
                                for: row.message.id, in: sdk.chat.currentSessionId
                            ),
                            onPromptReply: { cardIndex, label, value, galleryLabel in
                                Task {
                                    await sdk.chat.sendButtonReply(
                                        promptId: row.message.id,
                                        cardIndex: cardIndex,
                                        label: label,
                                        value: value,
                                        galleryLabel: galleryLabel
                                    )
                                }
                            }
                        )
                            .id(row.id)
                            .background(
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: ExampleTranscriptFramesKey.self,
                                        value: [row.id: geometry.frame(in: .named("example-transcript"))]
                                    )
                                }
                            )
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }

                    if sdk.chat.isTyping {
                        TypingIndicator()
                            .id("typing")
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .coordinateSpace(name: "example-transcript")
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: ExampleTranscriptSizeKey.self, value: geometry.size)
                }
            )
            .onPreferenceChange(ExampleTranscriptFramesKey.self) { frames in
                updateVisibleRows(frames)
            }
            .onPreferenceChange(ExampleTranscriptSizeKey.self) { size in
                guard size != .zero, size != transcriptSize else { return }
                let target = exampleViewportRestoreTarget(
                    visibleRowIds: visibleRowIds,
                    atTail: latestRowVisible,
                    tailId: transcriptRows.last?.id
                )
                transcriptSize = size
                guard positionedForVisit, let target else { return }
                DispatchQueue.main.async { proxy.scrollTo(target, anchor: latestRowVisible ? .bottom : .top) }
            }
            .onChange(of: messagePresentationToken) { _ in
                let decision = exampleTranscriptChangeDecision(
                    intent: sendFollowIntent,
                    outgoingLocalIds: outgoingLocalIds,
                    positioned: positionedForVisit,
                    wasAtTail: latestRowVisible
                )
                if decision.consumeIntent { sendFollowIntent = nil }
                if decision.followTail {
                    withAnimation(.easeOut(duration: 0.2)) { scrollToBottom(proxy: proxy) }
                } else if let anchor = visibleRowIds.first {
                    proxy.scrollTo(anchor, anchor: .top)
                }
                positionTranscriptIfReady(proxy: proxy)
            }
            .onChange(of: sdk.chat.isTyping) { _ in
                guard latestRowVisible else { return }
                withAnimation(.easeOut(duration: 0.2)) { scrollToBottom(proxy: proxy) }
            }
            .onChange(of: sdk.chat.focusedLoadState) { _ in
                positionTranscriptIfReady(proxy: proxy)
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    positionTranscriptIfReady(proxy: proxy)
                }
            }
        }
        .onTapGesture { isInputFocused = false }
    }

    private var newMessagesDivider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Origon.border).frame(height: 1)
            Text("NEW MESSAGES")
                .font(.caption.weight(.semibold))
                .foregroundColor(Origon.textSecondary)
            Rectangle().fill(Origon.border).frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(exampleNewMessagesAccessibilityLabel)
        .accessibilitySortPriority(1)
    }

    private var hasText: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasContent: Bool {
        hasText || !sdk.chat.pendingAttachments.isEmpty
    }

    private var composerBlocked: Bool {
        sdk.chat.currentSessionId != nil && !sdk.chat.canSendFocusedSession
    }

    private var primaryIsVoice: Bool {
        !hasContent && sdk.endpointPolicy.showsComposerVoiceAction
    }

    private var photoPickerFilter: PHPickerFilter {
        let policy = sdk.endpointPolicy.attachments
        switch (policy.images, policy.videos) {
        case (true, true):
            return PHPickerFilter.any(of: [PHPickerFilter.images, PHPickerFilter.videos])
        case (true, false): return PHPickerFilter.images
        case (false, true): return PHPickerFilter.videos
        case (false, false): return PHPickerFilter.images
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            if let status = connectionStatus {
                Text(status)
                    .font(.caption)
                    .foregroundColor(Origon.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .accessibilityLabel(status)
            }
            if !sdk.chat.pendingAttachments.isEmpty {
                attachmentsPreviewRow
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 8) {
                if sdk.chat.attachmentsAllowed { attachButton }

                TextField("Message", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .padding(.vertical, 8)
                    .disabled(composerBlocked)
                    .onChange(of: inputText) { newValue in
                        if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            sdk.chat.stopTyping()
                        } else {
                            sdk.chat.notifyTyping()
                        }
                    }

                sendOrWaveButton
                    .padding(.trailing, 2)
                    .padding(.bottom, 3)
            }
            .padding(.leading, 4)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hasContent)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: sdk.chat.pendingAttachments)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Origon.border, lineWidth: 1)
                .background(RoundedRectangle(cornerRadius: 24).fill(Origon.screenBackground))
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var connectionStatus: String? {
        guard sdk.chat.currentSessionId != nil else { return nil }
        switch sdk.chat.currentConnectionState {
        case .connected:
            return sdk.chat.canSendFocusedSession ? nil : "Opening conversation…"
        case .reconnecting: return "Reconnecting…"
        case .dropped: return "Connection lost. Your next message will retry."
        case .ended: return "Conversation ended. This transcript is read-only."
        }
    }

    private var attachButton: some View {
        Menu {
            if sdk.endpointPolicy.attachments.images || sdk.endpointPolicy.attachments.videos {
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
            }
            if sdk.endpointPolicy.attachments.images &&
                UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    showCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                }
            }
            if sdk.endpointPolicy.attachments.documents || sdk.endpointPolicy.attachments.audio {
                Button {
                    showFilePicker = true
                } label: {
                    Label("Files", systemImage: "folder")
                }
            }
        } label: {
            Image("AttachmentIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundColor(Origon.textSecondary)
                .frame(width: 32, height: 32)
        }
        .padding(.leading, 2)
        .padding(.bottom, 3)
        .disabled(isSending || composerBlocked)
        .simultaneousGesture(TapGesture().onEnded { isInputFocused = false })
    }

    private var sendOrWaveButton: some View {
        Button {
            if primaryIsVoice {
                isInputFocused = false
                onStartCall()
            } else {
                sendMessage()
            }
        } label: {
            ZStack {
                if isSending {
                    Circle()
                        .fill(Origon.accent.opacity(0.3))
                        .frame(width: 32, height: 32)
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Origon.accentForeground)
                        .scaleEffect(0.8)
                } else {
                    Circle()
                        .fill(Origon.accent)
                        .frame(width: 32, height: 32)
                    Image(primaryIsVoice ? "VoiceIcon" : "SendIcon")
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .foregroundColor(Origon.accentForeground)
                        .id(primaryIsVoice)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .disabled(isSending || composerBlocked || (!hasContent && !primaryIsVoice))
    }

    private var attachmentsPreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sdk.chat.pendingAttachments) { attachment in
                    AttachmentTile(attachment: attachment) {
                        sdk.chat.removePendingAttachment(id: attachment.id)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Behavior

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if sdk.chat.isTyping {
            proxy.scrollTo("typing", anchor: .bottom)
        } else if !sdk.chat.messages.isEmpty {
            proxy.scrollTo(sdk.chat.messages.count - 1, anchor: .bottom)
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !sdk.chat.pendingAttachments.isEmpty else { return }

        sendFollowIntent = .explicitSend(previousOutgoingLocalIds: outgoingLocalIds)
        Task {
            if sdk.chat.hasUploadingAttachments {
                await MainActor.run { isSending = true }
                await waitForUploads()
                await MainActor.run { isSending = false }
            }
            await MainActor.run { inputText = "" }
            await sdk.chat.sendMessage(text: text)
        }
    }

    private var resolvedCheckpointSessionId: String? {
        sessionId ?? sdk.chat.currentSessionId
    }

    private var checkpointTaskId: String {
        "\(sdk.checkpointEndpoint ?? "")\u{0}\(resolvedCheckpointSessionId ?? "")"
    }

    private var transcriptRows: [ExampleTranscriptRow] {
        sdk.chat.messages.enumerated().map { .init(index: $0.offset, message: $0.element) }
    }

    private var outgoingLocalIds: Set<String> {
        Set(sdk.chat.messages.compactMap { message in
            guard message.role == .external else { return nil }
            return message.localId?.isEmpty == false ? message.localId : nil
        })
    }

    private var messagePresentationToken: String {
        sdk.chat.messages.enumerated().map {
            "\(exampleTranscriptRowId($0.element, index: $0.offset)):\($0.element.id):\($0.element.action ?? ""):\($0.element.status)"
        }.joined(separator: "|")
    }

    private func resetTranscriptVisit() {
        checkpointLoaded = false
        checkpointLastSeenMessageId = nil
        unreadAnchorMessageId = nil
        positionedForVisit = false
        visibleRowIds = []
        latestRowVisible = false
        sendFollowIntent = nil
        lastCheckpointCandidate = nil
    }

    private func loadCheckpointForVisit() async {
        guard let id = resolvedCheckpointSessionId, !id.isEmpty else {
            checkpointLoaded = true
            return
        }
        let expected = checkpointTaskId
        let checkpoint = await sdk.checkpoint(sessionId: id)
        guard expected == checkpointTaskId else { return }
        checkpointLastSeenMessageId = checkpoint?.lastSeenMessageId
        unreadAnchorMessageId = exampleUnreadAnchorMessageId(
            messages: sdk.chat.messages,
            checkpointId: checkpointLastSeenMessageId
        )
        checkpointLoaded = true
    }

    private func positionTranscriptIfReady(proxy: ScrollViewProxy) {
        guard checkpointLoaded, sdk.chat.focusedHistoryIsAuthoritative,
              !positionedForVisit else { return }
        unreadAnchorMessageId = exampleUnreadAnchorMessageId(
            messages: sdk.chat.messages,
            checkpointId: checkpointLastSeenMessageId
        )
        let target = unreadAnchorMessageId.flatMap { anchor in
            transcriptRows.first(where: { $0.message.id == anchor })?.id
        } ?? transcriptRows.last?.id
        positionedForVisit = true
        guard let target else { return }
        proxy.scrollTo(target, anchor: unreadAnchorMessageId == nil ? .bottom : .top)
    }

    private func updateVisibleRows(_ frames: [String: CGRect]) {
        guard transcriptSize.height > 0 else { return }
        let visible = transcriptRows.compactMap { row -> String? in
            guard let frame = frames[row.id], frame.maxY > 0,
                  frame.minY < transcriptSize.height else { return nil }
            return row.id
        }
        visibleRowIds = visible
        let tailVisible = transcriptRows.last.map { visible.contains($0.id) } ?? false
        latestRowVisible = tailVisible
        guard tailVisible, sdk.chat.focusedHistoryIsAuthoritative,
              let id = resolvedCheckpointSessionId,
              let candidate = exampleNewestEligibleMessageId(sdk.chat.messages),
              candidate != lastCheckpointCandidate else { return }
        lastCheckpointCandidate = candidate
        Task {
            await sdk.markCheckpointSeen(
                sessionId: id,
                latestRowVisible: true,
                sceneForeground: scenePhase == .active
            )
        }
    }

    private func waitForUploads() async {
        while sdk.chat.hasUploadingAttachments {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func focusSessionIfNeeded() {
        guard !hasStartedSession else { return }
        hasStartedSession = true
        Task { await sdk.chat.openSession(id: sessionId) }
    }

    private func presentToast(_ message: String) {
        toastMessage = message
        withAnimation { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation { showToast = false }
        }
    }

    // MARK: - Pickers

    private func handlePhotoSelections(_ items: [PhotosPickerItem]) {
        for item in items {
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let (fileName, contentType) = inferFileInfo(from: item, data: data)
                let preview: UIImage? = contentType.hasPrefix("image/")
                    ? UIImage(data: data)
                    : nil
                await MainActor.run {
                    sdk.chat.uploadFile(
                        data: data,
                        fileName: fileName,
                        contentType: contentType,
                        previewImage: preview
                    )
                }
            }
        }
    }

    private func handleCapturedImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        let fileName = "IMG-\(Int(Date().timeIntervalSince1970)).jpg"
        sdk.chat.uploadFile(
            data: data,
            fileName: fileName,
            contentType: "image/jpeg",
            previewImage: image
        )
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else { continue }
            let fileName = url.lastPathComponent
            let contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            let preview: UIImage? = contentType.hasPrefix("image/")
                ? UIImage(data: data)
                : nil
            sdk.chat.uploadFile(
                data: data,
                fileName: fileName,
                contentType: contentType,
                previewImage: preview
            )
        }
    }

    private func inferFileInfo(from item: PhotosPickerItem, data: Data) -> (String, String) {
        let suggestedName = item.itemIdentifier ?? UUID().uuidString
        if let utType = item.supportedContentTypes.first {
            let ext = utType.preferredFilenameExtension ?? "dat"
            let mime = utType.preferredMIMEType ?? "application/octet-stream"
            return ("\(suggestedName).\(ext)", mime)
        }
        return ("\(suggestedName).jpg", "image/jpeg")
    }
}

// MARK: - Attachment tile

private struct AttachmentTile: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    private var overlayColor: Color {
        switch attachment.status {
        case .uploading: return Color.black.opacity(0.35)
        case .error: return Color.red.opacity(0.8)
        case .completed: return .clear
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                if let image = attachment.previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 80)
                        .clipped()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: iconName(for: attachment.contentType))
                            .font(.system(size: 22))
                            .foregroundColor(Origon.textSecondary)
                        Text(attachment.fileName)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundColor(Origon.textSecondary)
                            .padding(.horizontal, 4)
                    }
                    .frame(width: 80, height: 80)
                    .background(Origon.remoteBubble)
                    .overlay(alignment: .bottomTrailing) {
                        if !attachment.fileExtension.isEmpty {
                            Text(attachment.fileExtension)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(Origon.textSecondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Origon.border.opacity(0.6))
                                .cornerRadius(3)
                                .padding(4)
                        }
                    }
                }

                if attachment.status == .uploading {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Color.black.opacity(0.25)
                            Color.black.opacity(0.5)
                                .frame(width: geo.size.width * CGFloat(attachment.progress / 100))
                        }
                    }
                } else if attachment.status == .error {
                    Color.red.opacity(0.75)
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Origon.border, lineWidth: 0.5)
            )

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.red)
                    .clipShape(Circle())
            }
            .padding(4)
            .accessibilityLabel("Remove attachment")
        }
        .frame(width: 80, height: 80)
    }

    private func iconName(for contentType: String) -> String {
        let t = contentType.lowercased()
        switch true {
        case t == "application/pdf": return "doc.richtext"
        case t.hasPrefix("audio/"): return "waveform"
        case t.hasPrefix("video/"): return "play.rectangle"
        case t.contains("zip"): return "doc.zipper"
        case t.contains("word") || t.contains("document"): return "doc.text"
        case t.contains("sheet") || t.contains("excel"): return "tablecells"
        default: return "doc"
        }
    }
}
