//
//  BankService.swift
//  BunqAssignment
//

import Foundation

public protocol BankServiceProtocol {
    func fetchFeed(cursor: Int?) async throws -> TransactionResponse
    func createPayment(to: String, amount: Int, description: String, key: String) async throws -> PaymentResponse
}

public final class BankService: BankServiceProtocol {
    private let session: URLSession
    private let baseURL = URL(string: "https://bank.test/v1")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchFeed(cursor: Int?) async throws -> TransactionResponse {
        var components = URLComponents(url: baseURL.appending(path: "transactions"), resolvingAgainstBaseURL: false)!
        if let cursor {
            components.queryItems = [URLQueryItem(name: "cursor", value: String(cursor))]
        }

        let (data, response) = try await session.data(from: components.url!)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(TransactionResponse.self, from: data)
    }

    public func createPayment(to: String, amount: Int, description: String, key: String) async throws -> PaymentResponse {
        let url = baseURL.appending(path: "payments")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(
            PaymentRequest(
                toUsername: to,
                amountCents: amount,
                description: description,
                idempotencyKey: key
            )
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
            let delay = TimeInterval(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0.5
            try await Task.sleep(for: .seconds(delay))
            return try await createPayment(to: to, amount: amount, description: description, key: key)
        }

        guard [200, 201].contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(APIErrorPayload.self, from: data) {
                throw NSError(
                    domain: "APIError",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: apiError.error.message]
                )
            }
            throw NSError(domain: "APIError", code: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(PaymentResponse.self, from: data)
    }
}
