import Foundation
import Combine
import UserNotifications

extension Notification.Name {
    /// Posted when one of your photos gets approved/rejected by an admin (or a rescan) — see
    /// SocketManager's "photo_reviewed" case. AuthenticationManager listens so `currentUser`
    /// (and therefore every view reading it) reflects the change without a manual refresh.
    static let photoReviewed = Notification.Name("photoReviewed")
}

/// Real-time chat transport, backed by Foundation's native `URLSessionWebSocketTask` rather
/// than the Socket.IO client library — the socket.io-client-swift SPM package couldn't be
/// resolved through Xcode's headless package manager in this environment (network and git both
/// worked standalone, but `xcodebuild -resolvePackageDependencies` never completed a resolution
/// regardless of scheme/DerivedData state), so the backend was switched to a plain WebSocket
/// (`@fastify/websocket`, see backend/src/socket/handlers.ts) that this talks to directly with
/// zero external dependencies. Wire format is a simple `{"type": ..., "payload": ...}` envelope.
class SocketManager: ObservableObject {
    static let shared = SocketManager()

    // Keep in sync with APIService.baseURL
    private let socketURL = "ws://192.168.68.59:3000/ws"

    @Published var isConnected = false
    @Published var incomingMessages: [Message] = []
    @Published var typingUsers: [String: Bool] = [:]

    private var task: URLSessionWebSocketTask?
    private var shouldReconnect = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var pingCancellable: AnyCancellable?

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) { return date }

            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: dateString) { return date }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format")
        }
        return decoder
    }()

    private init() {}

    func connect() {
        guard let token = KeychainManager.shared.getAccessToken() else {
            print("No access token available for socket connection")
            return
        }
        guard let url = URL(string: socketURL) else { return }

        shouldReconnect = true
        reconnectWorkItem?.cancel()

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let newTask = URLSession.shared.webSocketTask(with: request)
        task = newTask
        newTask.resume()
        listen()
        startKeepAlive()
    }

    func disconnect() {
        shouldReconnect = false
        reconnectWorkItem?.cancel()
        pingCancellable?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isConnected = false
    }

    // MARK: - Sending

    func sendMessage(matchId: String, content: String?, imageUrl: String?) {
        var payload: [String: Any] = ["matchId": matchId]
        if let content { payload["content"] = content }
        if let imageUrl { payload["imageUrl"] = imageUrl }
        sendEnvelope(type: "send_message", payload: payload)
    }

    func sendTypingIndicator(matchId: String, isTyping: Bool) {
        sendEnvelope(type: "typing", payload: ["matchId": matchId, "isTyping": isTyping])
    }

    func markMessagesAsRead(matchId: String) {
        sendEnvelope(type: "mark_read", payload: ["matchId": matchId])
    }

    private func sendEnvelope(type: String, payload: [String: Any]) {
        guard let task else {
            print("Socket not connected")
            return
        }
        let envelope: [String: Any] = ["type": type, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        task.send(.data(data)) { error in
            if let error { print("Socket send error: \(error)") }
        }
    }

    // MARK: - Receiving

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                print("Socket receive error: \(error)")
                self.handleDisconnect()
            case .success(let message):
                switch message {
                case .data(let data):
                    self.handleIncoming(data)
                case .string(let text):
                    self.handleIncoming(Data(text.utf8))
                @unknown default:
                    break
                }
                self.listen()
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        let payload = json["payload"] as? [String: Any] ?? [:]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return }

        switch type {
        case "connected":
            DispatchQueue.main.async { self.isConnected = true }

        case "new_message":
            struct IncomingMessage: Codable {
                let messageId: String
                let matchId: String
                let senderId: String
                let content: String?
                let imageUrl: String?
                let createdAt: Date
            }
            guard let incoming = try? decoder.decode(IncomingMessage.self, from: payloadData) else { return }
            let message = Message(
                id: incoming.messageId,
                matchId: incoming.matchId,
                senderId: incoming.senderId,
                content: incoming.content,
                imageUrl: incoming.imageUrl,
                createdAt: incoming.createdAt,
                readAt: nil
            )
            DispatchQueue.main.async { self.incomingMessages.append(message) }

        case "user_typing":
            struct TypingPayload: Codable { let userId: String; let isTyping: Bool }
            guard let typing = try? decoder.decode(TypingPayload.self, from: payloadData) else { return }
            DispatchQueue.main.async { self.typingUsers[typing.userId] = typing.isTyping }

        case "messages_read":
            break // Chat view doesn't currently render per-message read state from the socket feed.

        case "photo_reviewed":
            struct PhotoReviewedPayload: Codable { let photoId: String; let status: String }
            guard let reviewed = try? decoder.decode(PhotoReviewedPayload.self, from: payloadData) else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .photoReviewed, object: nil)
                self.notifyPhotoReviewed(status: reviewed.status)
            }

        case "photo_appeal_reviewed":
            struct AppealReviewedPayload: Codable { let photoId: String; let outcome: String }
            guard let reviewed = try? decoder.decode(AppealReviewedPayload.self, from: payloadData) else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .photoReviewed, object: nil)
                if reviewed.outcome == "approved" {
                    self.showLocalNotification(title: "Appeal Approved", body: "Your photo is back on your profile.")
                } else {
                    self.showLocalNotification(title: "Appeal Denied", body: "The original decision on your photo stands.")
                }
            }

        // Live parity for a socket-connected recipient with what an offline user gets via a
        // real push (see notifyUser() in backend/src/utils/notify.ts) — same on-device banner
        // either way, just a different transport depending on whether the app is open.
        case "new_match":
            DispatchQueue.main.async {
                self.showLocalNotification(title: "It's a Match!", body: "You have a new match on Lumen.")
            }

        case "new_like":
            DispatchQueue.main.async {
                self.showLocalNotification(title: "New Like", body: "Someone likes you on Lumen.")
            }

        case "error":
            if let message = payload["message"] as? String {
                print("Socket error from server: \(message)")
            }

        default:
            break
        }
    }

    private func notifyPhotoReviewed(status: String) {
        switch status {
        case "approved":
            showLocalNotification(title: "Photo Approved", body: "One of your photos is now live on your profile.")
        case "rejected":
            showLocalNotification(title: "Photo Removed", body: "One of your photos didn't pass review and was removed.")
        default:
            break
        }
    }

    private func showLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func handleDisconnect() {
        DispatchQueue.main.async { self.isConnected = false }
        pingCancellable?.cancel()
        guard shouldReconnect else { return }

        let workItem = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    /// A lightweight app-level "ping" every 30s doubles as transport keep-alive (any traffic
    /// resets idle timeouts on the way) and refreshes the server's Redis online-status TTL —
    /// see the `ping` case in backend/src/socket/handlers.ts.
    private func startKeepAlive() {
        pingCancellable?.cancel()
        pingCancellable = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.sendEnvelope(type: "ping", payload: [:])
            }
    }
}
