import Foundation

public struct Transaction: Codable, Identifiable, Equatable {
    public let id: String
    public let fromUsername: String
    public let toUsername: String
    public let amountCents: Int
    public let description: String
    public var status: Status
    public var rejectionReason: String?
    public let idempotencyKey: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fromUsername = "from_username"
        case toUsername = "to_username"
        case amountCents = "amount_cents"
        case description, status
        case rejectionReason = "rejection_reason"
        case idempotencyKey = "idempotency_key"
    }

    public enum Status: String, Codable, Equatable {
        case pending
        case completed
        case rejected
    }
}

public struct TransactionResponse: Codable {
    public let transactions: [Transaction]
    public let cursor: Int
    public let balanceCents: Int

    enum CodingKeys: String, CodingKey {
        case transactions, cursor
        case balanceCents = "balance_cents"
    }
}

public struct PaymentRequest: Codable {
    public let toUsername: String
    public let amountCents: Int
    public let description: String
    public let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case toUsername = "to_username"
        case amountCents = "amount_cents"
        case description
        case idempotencyKey = "idempotency_key"
    }
}

public struct PaymentResponse: Codable {
    public let transaction: Transaction
    public let replayed: Bool
}

public struct APIErrorPayload: Codable {
    public struct ErrorDetail: Codable {
        public let code: String
        public let message: String
    }

    public let error: ErrorDetail
}

/// A durable local record of a payment whose bank outcome is not yet confirmed.
public enum LocalPaymentState: Codable, Equatable {
    case unconfirmed(idempotencyKey: String, amount: Int, destination: String, desc: String)
    case apiPending(transaction: Transaction)
    case failedMidFlight(idempotencyKey: String, amount: Int, destination: String, desc: String)
    case notSent(idempotencyKey: String, amount: Int, destination: String, desc: String)
}
