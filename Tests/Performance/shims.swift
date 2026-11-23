import UserNotifications

func T(_ text: String) -> String { text }

@MainActor
final class NotificationService {
    static let shared = NotificationService()
    var status: UNAuthorizationStatus = .notDetermined
    func refresh() {}
    func request() async -> Bool { false }
}
