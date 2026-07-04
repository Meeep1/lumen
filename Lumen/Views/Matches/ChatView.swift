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
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
            
            // Message input
            HStack(spacing: 12) {
                TextField("Message...", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color(uiColor: .systemGray6))
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
                        .foregroundStyle(messageText.isEmpty ? .gray : .pink)
                }
                .disabled(messageText.isEmpty)
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    showingProfile = true
                } label: {
                    HStack(spacing: 6) {
                        AsyncImage(url: APIService.shared.imageURL(for: match.photo)) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Circle().fill(Color(uiColor: .systemGray5))
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
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingOptions = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
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
        
        // Send via socket for real-time delivery
        socketManager.sendMessage(matchId: match.matchId, content: text, imageUrl: nil)
        
        // Also send via API for persistence
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
                        .background(isFromCurrentUser ? Color.pink : Color(uiColor: .systemGray5))
                        .foregroundColor(isFromCurrentUser ? .white : .primary)
                        .cornerRadius(16)
                }
                
                if let imageUrl = APIService.shared.imageURL(for: message.imageUrl) {
                    AsyncImage(url: imageUrl) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle()
                            .fill(Color(uiColor: .systemGray5))
                            .overlay {
                                ProgressView()
                            }
                    }
                    .frame(maxWidth: 200, maxHeight: 200)
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
