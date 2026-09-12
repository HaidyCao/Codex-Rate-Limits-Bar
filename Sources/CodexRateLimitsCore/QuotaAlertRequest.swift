import Foundation

/// A unique notification-center submission. The event identifier remains stable
/// for deduplication; the request identifier fences cancellation and late replies.
public struct QuotaAlertRequest: Sendable {
    public let event: QuotaAlertEvent
    public let identifier: String
}

struct ActiveQuotaAlert {
    let request: QuotaAlertRequest
    let identity: String
    let deadline: Date
    var accepted = false
}
