import SwiftUI
import PhotosUI

struct ChatView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @EnvironmentObject var socketManager: SocketManager
    @Environment(\.dismiss) var dismiss

    let match: Match
    @State private var messages: [Message] = []
    @State private var messageText = ""
    @State private var isLoading = false
    @State private var showingOptions = false
    @State private var showingProfile = false
    @State private var showingReportSheet = false
    @State private var typingStoppedTask: Task<Void, Never>?
    @State private var imagePickerItem: PhotosPickerItem?
    @State private var isSendingImage = false
    @State private var imageSendErrorMessage: String?

    /// The most recent message the *current* user sent — the only one a "Read" receipt ever
    /// renders under, matching common chat UX (no per-message read marks, just the latest one).
    private var lastOwnMessage: Message? {
        messages.last(where: { $0.senderId == authManager.currentUser?.id })
    }
    
    var body: some View {
        VStack(spacing: 0) {
            LumenHeader(title: "", leading: {
                LumenBackButton()
            }, trailing: {
                HStack(spacing: 12) {
                    Button {
                        showingProfile = true
                    } label: {
                        HStack(spacing: 6) {
                            AsyncImage(url: APIService.shared.imageURL(for: match.photo)) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Circle().fill(Color.lumenSurfaceStrong)
                            }
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())

                            Text("\(match.age)")
                                .font(.headline)
                                .foregroundColor(.primary)

                            if match.isVerified {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .buttonStyle(LumenPressableStyle())

                    Button {
                        showingOptions = true
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .buttonStyle(LumenIconButtonStyle())
                }
            })

            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubble(
                                message: message,
                                isFromCurrentUser: message.senderId == authManager.currentUser?.id,
                                showReadReceipt: message.id == lastOwnMessage?.id && message.readAt != nil
                            )
                            .id(message.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }

                        if socketManager.typingUsers[match.userId] == true {
                            TypingIndicatorBubble()
                                .id("typing-indicator")
                        }
                    }
                    .padding()
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: messages.count)
                    .animation(.easeInOut(duration: 0.2), value: socketManager.typingUsers[match.userId])
                }
                .onChange(of: messages.count) { _, _ in
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: socketManager.typingUsers[match.userId]) { _, isTyping in
                    guard isTyping == true else { return }
                    withAnimation {
                        proxy.scrollTo("typing-indicator", anchor: .bottom)
                    }
                }
            }
        }
        // A plain trailing VStack child used to hold this instead — harmless on its own, but
        // MainTabView's custom tab bar (a manual `.safeAreaInset`, not a native tabItem) stays
        // reserved at the bottom for every pushed screen inside a tab, since it never got
        // UIKit's automatic "hide tab bar when pushed" behavior. That left no room for this row
        // to render at all while chatting — see TabBarVisibility for the other half of this fix.
        // `.safeAreaInset` is also just the correct, keyboard-aware way to anchor a chat input bar
        // regardless of that issue.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()

                HStack(spacing: 12) {
                    PhotosPicker(selection: $imagePickerItem, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title3)
                            .foregroundStyle(isSendingImage ? AnyShapeStyle(Color.gray) : AnyShapeStyle(Theme.primaryGradient))
                    }
                    .disabled(isSendingImage)

                    TextField("Message...", text: $messageText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(Color.lumenSurface)
                        .cornerRadius(20)
                        .lineLimit(1...5)
                        .onChange(of: messageText) { oldValue, newValue in
                            handleTypingChange(from: oldValue, to: newValue)
                        }

                    Button {
                        Task {
                            await sendMessage()
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .resizable()
                            .frame(width: 32, height: 32)
                            .foregroundStyle(messageText.isEmpty ? AnyShapeStyle(Color.gray) : AnyShapeStyle(Theme.primaryGradient))
                    }
                    .buttonStyle(LumenPressableStyle())
                    .disabled(messageText.isEmpty)
                }
                .padding()
            }
            .background(Color.lumenBackground)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { TabBarVisibility.shared.isHidden = true }
        .onDisappear {
            TabBarVisibility.shared.isHidden = false
            typingStoppedTask?.cancel()
            socketManager.sendTypingIndicator(matchId: match.matchId, isTyping: false)
        }
        .onChange(of: imagePickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await sendPickedImage(newItem)
                imagePickerItem = nil
            }
        }
        .customAlert(
            isPresented: Binding(
                get: { imageSendErrorMessage != nil },
                set: { if !$0 { imageSendErrorMessage = nil } }
            ),
            title: "Couldn't Send Photo",
            message: imageSendErrorMessage ?? ""
        )
        .customConfirmation(
            isPresented: $showingOptions,
            title: "Options",
            actions: [
                CustomSheetAction(title: "View Profile", systemImage: "person.circle") {
                    showingProfile = true
                },
                CustomSheetAction(title: "Report", systemImage: "flag", isDestructive: true) {
                    showingReportSheet = true
                },
                CustomSheetAction(title: "Unmatch", systemImage: "heart.slash", isDestructive: true) {
                    Task { await unmatch() }
                },
            ]
        )
        .sheet(isPresented: $showingProfile) {
            MatchProfileView(userId: match.userId, onUnmatch: {
                Task { await unmatch() }
            })
        }
        .sheet(isPresented: $showingReportSheet) {
            ReportUserSheet(reportedId: match.userId)
        }
        .task {
            await loadMessages()
            
            // Mark messages as read
            socketManager.markMessagesAsRead(matchId: match.matchId)
        }
        .onReceive(socketManager.$incomingMessages) { newMessages in
            // Add new messages from socket
            for newMessage in newMessages where newMessage.matchId == match.matchId {
                if !messages.contains(where: { $0.id == newMessage.id }) {
                    messages.append(newMessage)
                }
            }
        }
        .onReceive(socketManager.$lastReadReceipt) { receipt in
            // The other participant just read whatever we've sent them so far in this match —
            // Message is a value type, so this rebuilds each now-read entry rather than mutating
            // one in place.
            guard let receipt, receipt.matchId == match.matchId else { return }
            let myId = authManager.currentUser?.id
            messages = messages.map { message in
                guard message.senderId == myId, message.readAt == nil else { return message }
                return Message(
                    id: message.id, matchId: message.matchId, senderId: message.senderId,
                    content: message.content, imageUrl: message.imageUrl,
                    createdAt: message.createdAt, readAt: receipt.at
                )
            }
        }
    }

    private func handleTypingChange(from oldValue: String, to newValue: String) {
        typingStoppedTask?.cancel()

        if newValue.isEmpty {
            socketManager.sendTypingIndicator(matchId: match.matchId, isTyping: false)
            return
        }
        if oldValue.isEmpty {
            socketManager.sendTypingIndicator(matchId: match.matchId, isTyping: true)
        }

        // No further keystrokes for 3s reads as "stopped typing" — avoids leaving the other
        // person staring at a stale "typing..." indicator if you pause without sending or
        // clearing the field.
        typingStoppedTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                socketManager.sendTypingIndicator(matchId: match.matchId, isTyping: false)
            }
        }
    }
    
    private func loadMessages() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            messages = try await APIService.shared.getMessages(matchId: match.matchId)
        } catch {
            print("Failed to load messages: \(error)")
        }
    }
    
    private func sendMessage() async {
        guard !messageText.isEmpty else { return }

        let text = messageText
        messageText = ""
        typingStoppedTask?.cancel()
        socketManager.sendTypingIndicator(matchId: match.matchId, isTyping: false)

        // REST only, not also the socket — the backend delivers this to the other participant
        // (and pushes if they're offline) as a side effect of creating it either way, so sending
        // through both created two separate messages for one send. REST also gives a real
        // async result to await/catch, unlike the socket's fire-and-forget send.
        do {
            let message = try await APIService.shared.sendMessage(
                matchId: match.matchId,
                message: SendMessage(content: text, imageUrl: nil)
            )
            
            // Add to local messages if not already there from socket
            if !messages.contains(where: { $0.id == message.id }) {
                messages.append(message)
            }
        } catch {
            print("Failed to send message: \(error)")
        }
    }

    /// The unlock-threshold check itself lives entirely server-side (see match.ts's POST
    /// /:matchId/messages/photo) rather than being duplicated here as a client-side gate — this
    /// just surfaces whatever the server says, including "exchange N more messages first" if
    /// it's too early, so the two can never drift out of sync with each other.
    private func sendPickedImage(_ item: PhotosPickerItem) async {
        isSendingImage = true
        defer { isSendingImage = false }

        do {
            guard
                let data = try await item.loadTransferable(type: Data.self),
                let uiImage = UIImage(data: data),
                let jpegData = uiImage.jpegData(compressionQuality: 0.85)
            else {
                imageSendErrorMessage = "Couldn't read that image — try a different one."
                return
            }

            let message = try await APIService.shared.sendChatImage(matchId: match.matchId, imageData: jpegData)
            if !messages.contains(where: { $0.id == message.id }) {
                messages.append(message)
            }
        } catch {
            imageSendErrorMessage = error.localizedDescription
        }
    }

    private func unmatch() async {
        do {
            try await APIService.shared.unmatch(matchId: match.matchId)
            dismiss()
        } catch {
            print("Failed to unmatch: \(error)")
        }
    }
}

struct MessageBubble: View {
    let message: Message
    let isFromCurrentUser: Bool
    var showReadReceipt: Bool = false

    var body: some View {
        HStack {
            if isFromCurrentUser {
                Spacer()
            }

            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: 4) {
                if let content = message.content {
                    Text(content)
                        .padding(12)
                        .background(isFromCurrentUser ? AnyShapeStyle(Theme.primaryGradient) : AnyShapeStyle(Color.lumenSurfaceStrong))
                        .foregroundColor(isFromCurrentUser ? .white : .primary)
                        .cornerRadius(16)
                }

                if let imageUrl = APIService.shared.imageURL(for: message.imageUrl) {
                    // Fixed width AND height, not maxWidth/maxHeight — matches the same fix
                    // ProfileCardView/etc. already needed (see their own comments): `.fill`
                    // makes an image *report* its overflowed size to layout, and a max-only frame
                    // has no floor, so the surrounding VStack could collapse this down to a thin
                    // sliver instead of an actual 200x200 square. Overlay content never
                    // participates in layout, so no photo aspect ratio can distort the bubble.
                    Color.clear
                        .frame(width: 200, height: 200)
                        .overlay {
                            AsyncImage(url: imageUrl) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Rectangle()
                                    .fill(Color.lumenSurfaceStrong)
                                    .overlay { ProgressView() }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if showReadReceipt {
                    Text("Read")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !isFromCurrentUser {
                Spacer()
            }
        }
    }
}

/// Mirrors MessageBubble's own-message-on-the-right / other-on-the-left layout so it slots into
/// the same LazyVStack without looking out of place, but with animated dots instead of text.
/// `TimelineView` (not a manual `Timer`) drives the animation — it only ticks while this view is
/// actually on screen, so there's nothing to invalidate when the typing indicator disappears.
struct TypingIndicatorBubble: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let activeDot = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3

            HStack {
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Circle()
                            .frame(width: 6, height: 6)
                            .foregroundStyle(.secondary)
                            .opacity(activeDot == index ? 1 : 0.3)
                    }
                }
                .padding(12)
                .background(Color.lumenSurfaceStrong)
                .cornerRadius(16)

                Spacer()
            }
        }
    }
}

#Preview {
    NavigationStack {
        ChatView(match: Match(
            matchId: "1",
            userId: "2",
            age: 25,
            genderIdentity: .woman,
            cityDisplay: "New York",
            isVerified: true,
            photo: nil,
            isOnline: true,
            lastActiveAt: Date(),
            lastMessage: nil,
            matchedAt: Date()
        ))
        .environmentObject(AuthenticationManager.shared)
        .environmentObject(SocketManager.shared)
    }
}
