import UserNotifications

public protocol CompletionNotifying: Sendable {
    func notify(title: String, body: String) async
}

public struct UserCompletionNotifier: CompletionNotifying {
    public init() {}
    public func notify(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
