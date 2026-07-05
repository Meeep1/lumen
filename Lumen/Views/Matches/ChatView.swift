import SwiftUI

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
                                isFromCurrentUser: message.senderId == authManager.currentUser?.id
                            )
                            .id(message.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }
                    }
                    .padding()
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: messages.count)
                }
                .onChange(of: messages.count) { _, _ in
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
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
                    TextField("Message...", text: $messageText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(Color.lumenSurface)
                        .cornerRadius(20)
                        .lineLimit(1...5)

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
        .onDisappear { TabBarVisibility.shared.isHidden = false }
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
                    Color.clear
                        .frame(maxWidth: 200, maxHeight: 200)
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
            }
            
            if !isFromCurrentUser {
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
            lastMessage: nil,
            matchedAt: Date()
        ))
        .environmentObject(AuthenticationManager.shared)
        .environmentObject(SocketManager.shared)
    }
}
