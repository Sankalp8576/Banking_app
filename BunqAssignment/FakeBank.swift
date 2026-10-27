//
//  FakeBank.swift
//  BunqAssignment
//

import Foundation

public final class FakeBank: URLProtocol {
    public static var lostAnswer = false
    public static var unreachable = false
    public static var busy = false
    public static var repeatedEntries = false
    public static var balanceAhead = false
    /// Enables a manually triggered rejection after a payment has completed.
    public static var lateRejection = false

    private static let lock = NSLock()
    public static var balances: [String: Int] = [
        "eva": 100000, "alex": 100000, "mila": 100000, "noor": 100000
    ]
    public static var transactions: [Transaction] = []
    public static var cursorCount = 0
    public static var unreleasedTransactions: [Transaction] = []

    private static var changeLog: [(cursor: Int, transactionID: String)] = []
    private static var busyCounter = 0

    public static func reset() {
        lock.lock()
        defer { lock.unlock() }

        balances = ["eva": 100000, "alex": 100000, "mila": 100000, "noor": 100000]
        transactions = []
        unreleasedTransactions = []
        cursorCount = 0
        changeLog = []
        busyCounter = 0
        lostAnswer = false
        unreachable = false
        busy = false
        repeatedEntries = false
        balanceAhead = false
        lateRejection = false
    }

    public static func simulateExternalPayment(from: String, to: String, amount: Int, description: String) {
        lock.lock()
        defer { lock.unlock() }

        balances[from, default: 0] -= amount
        balances[to, default: 0] += amount
        let transaction = Transaction(
            id: "txn_\(UUID().uuidString.prefix(8).lowercased())",
            fromUsername: from,
            toUsername: to,
            amountCents: amount,
            description: description,
            status: .completed,
            rejectionReason: nil,
            idempotencyKey: nil
        )

        if balanceAhead && to == "eva" {
            unreleasedTransactions.append(transaction)
        } else {
            transactions.append(transaction)
            recordChange(for: transaction.id)
        }
    }

    public static func releaseAheadPayments() {
        lock.lock()
        defer { lock.unlock() }

        for transaction in unreleasedTransactions {
            transactions.append(transaction)
            recordChange(for: transaction.id)
        }
        unreleasedTransactions.removeAll()
    }

    public static func settlePendingPayments() {
        lock.lock()
        defer { lock.unlock() }

        for index in transactions.indices where transactions[index].status == .pending {
            transactions[index].status = .completed
            balances[transactions[index].toUsername, default: 0] += transactions[index].amountCents
            recordChange(for: transactions[index].id)
        }
    }

    public static func triggerLateRejection(id: String, reason: String) {
        lock.lock()
        defer { lock.unlock() }

        guard lateRejection,
              let index = transactions.firstIndex(where: { $0.id == id }),
              transactions[index].status == .completed else {
            return
        }

        transactions[index].status = .rejected
        transactions[index].rejectionReason = reason
        balances[transactions[index].fromUsername, default: 0] += transactions[index].amountCents
        balances[transactions[index].toUsername, default: 0] -= transactions[index].amountCents
        recordChange(for: id)
        lateRejection = false
    }

    override public class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "bank.test"
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override public func startLoading() {
        FakeBank.lock.lock()
        let isUnreachable = FakeBank.unreachable
        let isBusy = FakeBank.busy
        let isLostAnswer = FakeBank.lostAnswer
        FakeBank.lock.unlock()

        if isUnreachable {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.notConnectedToInternet)
            )
            return
        }

        if isBusy {
            FakeBank.lock.lock()
            FakeBank.busyCounter += 1
            let use429 = FakeBank.busyCounter == 1
            if FakeBank.busyCounter >= 2 {
                FakeBank.busy = false
            }
            FakeBank.lock.unlock()

            let status = use429 ? 429 : 503
            let headers = use429 ? ["Retry-After": "1"] : [:]
            send(status: status, data: Data(), headers: headers)
            return
        }

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        switch (url.path, request.httpMethod) {
        case ("/v1/transactions", _):
            handleFeedRequest(url: url)
        case ("/v1/payments", "POST"):
            if isLostAnswer {
                FakeBank.lock.lock()
                FakeBank.lostAnswer = false
                FakeBank.lock.unlock()
                _ = processPaymentMutation(request: request)
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else {
                handlePostPayment(request: request)
            }
        default:
            send(status: 404, data: Data())
        }
    }

    override public func stopLoading() {}

    private static func recordChange(for transactionID: String) {
        cursorCount += 1
        changeLog.append((cursor: cursorCount, transactionID: transactionID))
    }

    private func handleFeedRequest(url: URL) {
        FakeBank.lock.lock()
        defer { FakeBank.lock.unlock() }

        let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "cursor" })?
            .value
            .flatMap(Int.init)

        let feed: [Transaction]
        if FakeBank.repeatedEntries {
            feed = FakeBank.transactions + FakeBank.transactions
        } else if let cursor {
            feed = FakeBank.changeLog
                .filter { $0.cursor > cursor }
                .compactMap { change in FakeBank.transactions.first(where: { $0.id == change.transactionID }) }
        } else {
            feed = FakeBank.transactions
        }

        let payload = TransactionResponse(
            transactions: feed,
            cursor: FakeBank.cursorCount,
            balanceCents: FakeBank.balances["eva", default: 0]
        )
        send(status: 200, data: try! JSONEncoder().encode(payload), headers: ["Content-Type": "application/json"])
    }

    private func handlePostPayment(request: URLRequest) {
        let result = processPaymentMutation(request: request)
        send(status: result.status, data: result.data, headers: ["Content-Type": "application/json"])
    }

    private func processPaymentMutation(request: URLRequest) -> (status: Int, data: Data) {
        FakeBank.lock.lock()
        defer { FakeBank.lock.unlock() }

        let body = request.httpBody ?? request.httpBodyStreamData() ?? Data()
        guard let payment = try? JSONDecoder().decode(PaymentRequest.self, from: body) else {
            return errorResponse(status: 422, code: "malformed", message: "Bad JSON")
        }
        guard ["alex", "mila", "noor"].contains(payment.toUsername) else {
            return errorResponse(status: 404, code: "unknown_user", message: "Unknown user.")
        }
        guard payment.amountCents > 0 else {
            return errorResponse(status: 422, code: "invalid_amount", message: "Invalid amount.")
        }
        guard payment.toUsername != "eva" else {
            return errorResponse(status: 422, code: "self_payment", message: "Cannot pay yourself.")
        }
        guard FakeBank.balances["eva", default: 0] >= payment.amountCents else {
            return errorResponse(status: 422, code: "insufficient_funds", message: "Not enough money.")
        }

        if let existing = FakeBank.transactions.first(where: {
            $0.fromUsername == "eva" && $0.idempotencyKey == payment.idempotencyKey
        }) {
            return (200, try! JSONEncoder().encode(PaymentResponse(transaction: existing, replayed: true)))
        }

        FakeBank.balances["eva", default: 0] -= payment.amountCents
        let transaction = Transaction(
            id: "txn_\(UUID().uuidString.prefix(8).lowercased())",
            fromUsername: "eva",
            toUsername: payment.toUsername,
            amountCents: payment.amountCents,
            description: payment.description,
            status: .pending,
            rejectionReason: nil,
            idempotencyKey: payment.idempotencyKey
        )
        FakeBank.transactions.append(transaction)
        FakeBank.recordChange(for: transaction.id)

        return (201, try! JSONEncoder().encode(PaymentResponse(transaction: transaction, replayed: false)))
    }

    private func errorResponse(status: Int, code: String, message: String) -> (status: Int, data: Data) {
        let payload = APIErrorPayload(error: .init(code: code, message: message))
        return (status, try! JSONEncoder().encode(payload))
    }

    private func send(status: Int, data: Data, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

extension URLRequest {
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 1024)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
