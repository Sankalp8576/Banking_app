import Foundation
import Observation

@MainActor
@Observable
public final class BankViewModel {
    public private(set) var balanceCents = 100_000
    public private(set) var transactions: [Transaction] = []
    public private(set) var localPaymentState: LocalPaymentState?
    public private(set) var networkError: String?
    public private(set) var isBalancePossiblyOutOfDate = false

    public var balance: Double {
        Double(balanceCents) / 100
    }

    private let service: BankServiceProtocol
    private let paymentStateKey = "bunq.local.state"
    private let transactionsKey = "bunq.local.txns"
    private let balanceKey = "bunq.local.balance"
    private let cursorKey = "bunq.local.cursor"
    private let staleBalanceKey = "bunq.local.staleBalance"
    private var lastCursor: Int?

    public init(service: BankServiceProtocol) {
        self.service = service
        loadFromDisk()
    }

    public func loadFromDisk() {
        if let data = UserDefaults.standard.data(forKey: paymentStateKey) {
            localPaymentState = try? JSONDecoder().decode(LocalPaymentState.self, from: data)
        }
        if let data = UserDefaults.standard.data(forKey: transactionsKey),
           let savedTransactions = try? JSONDecoder().decode([Transaction].self, from: data) {
            transactions = savedTransactions
        }

        if UserDefaults.standard.object(forKey: balanceKey) != nil {
            balanceCents = UserDefaults.standard.integer(forKey: balanceKey)
        }
        if UserDefaults.standard.object(forKey: cursorKey) != nil {
            lastCursor = UserDefaults.standard.integer(forKey: cursorKey)
        }
        isBalancePossiblyOutOfDate = UserDefaults.standard.bool(forKey: staleBalanceKey)
    }

    /// Refreshes the local view from the bank. It never sends a payment by itself.
    public func sync() async {
        networkError = nil

        do {
            let response = try await service.fetchFeed(cursor: lastCursor)
            balanceCents = response.balanceCents
            lastCursor = response.cursor
            isBalancePossiblyOutOfDate = false

            for transaction in response.transactions {
                upsert(transaction)
                resolveLocalPaymentIfConfirmed(by: transaction)
            }

            // If the app died after persisting the tap but before it learned the
            // request result, this successful feed response is authoritative.
            // A matching transaction has already cleared the local state above;
            // no match means the bank did not receive the payment.
            markUnresolvedPaymentAsNotSentAfterSuccessfulSync()
            saveToDisk()
        } catch {
            isBalancePossiblyOutOfDate = true
            networkError = "Bank is unreachable. Showing the last known balance."
            saveToDisk()
        }
    }

    public func initiatePayment(to destination: String, amountCents: Int, description: String) async {
        guard localPaymentState == nil else { return }

        let idempotencyKey = UUID().uuidString
        await sendPayment(
            key: idempotencyKey,
            amount: amountCents,
            destination: destination,
            description: description
        )
    }

    /// The person explicitly chooses to retry a payment that did not reach the bank.
    public func retryNotSentPayment() async {
        guard case let .notSent(key, amount, destination, description) = localPaymentState else {
            return
        }

        await sendPayment(
            key: key,
            amount: amount,
            destination: destination,
            description: description
        )
    }

    private func sendPayment(
        key: String,
        amount: Int,
        destination: String,
        description: String
    ) async {
        networkError = nil
        localPaymentState = .unconfirmed(
            idempotencyKey: key,
            amount: amount,
            destination: destination,
            desc: description
        )
        saveToDisk()

        do {
            let response = try await service.createPayment(
                to: destination,
                amount: amount,
                description: description,
                key: key
            )
            upsert(response.transaction)
            localPaymentState = .apiPending(transaction: response.transaction)
            isBalancePossiblyOutOfDate = false
        } catch let error as URLError {
            handleTransportError(
                error,
                key: key,
                amount: amount,
                destination: destination,
                description: description
            )
        } catch let error as NSError where error.domain == NSURLErrorDomain {
            handleTransportError(
                URLError(URLError.Code(rawValue: error.code)),
                key: key,
                amount: amount,
                destination: destination,
                description: description
            )
        } catch {
            localPaymentState = nil
            networkError = error.localizedDescription
        }
        saveToDisk()
    }

    private func handleTransportError(
        _ error: URLError,
        key: String,
        amount: Int,
        destination: String,
        description: String
    ) {
        switch error.code {
        case .networkConnectionLost:
            localPaymentState = .failedMidFlight(
                idempotencyKey: key,
                amount: amount,
                destination: destination,
                desc: description
            )
            networkError = "Connection lost. Verify the payment with Sync."
        case .notConnectedToInternet:
            localPaymentState = .notSent(
                idempotencyKey: key,
                amount: amount,
                destination: destination,
                desc: description
            )
            networkError = "No connection. This payment was not sent."
        default:
            localPaymentState = .notSent(
                idempotencyKey: key,
                amount: amount,
                destination: destination,
                desc: description
            )
            networkError = error.localizedDescription
        }
        isBalancePossiblyOutOfDate = true
    }

    private func resolveLocalPaymentIfConfirmed(by transaction: Transaction) {
        switch localPaymentState {
        case let .apiPending(localTransaction) where localTransaction.id == transaction.id:
            localPaymentState = nil
        case let .failedMidFlight(key, _, _, _) where transaction.idempotencyKey == key:
            localPaymentState = nil
        case let .unconfirmed(key, _, _, _) where transaction.idempotencyKey == key:
            localPaymentState = nil
        default:
            break
        }
    }

    private func markUnresolvedPaymentAsNotSentAfterSuccessfulSync() {
        switch localPaymentState {
        case let .unconfirmed(key, amount, destination, description),
             let .failedMidFlight(key, amount, destination, description):
            localPaymentState = .notSent(
                idempotencyKey: key,
                amount: amount,
                destination: destination,
                desc: description
            )
        default:
            break
        }
    }

    private func upsert(_ transaction: Transaction) {
        if let index = transactions.firstIndex(where: { $0.id == transaction.id }) {
            transactions[index] = transaction
        } else {
            transactions.append(transaction)
        }
    }

    private func saveToDisk() {
        if let data = try? JSONEncoder().encode(localPaymentState) {
            UserDefaults.standard.set(data, forKey: paymentStateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: paymentStateKey)
        }
        if let data = try? JSONEncoder().encode(transactions) {
            UserDefaults.standard.set(data, forKey: transactionsKey)
        }
        UserDefaults.standard.set(balanceCents, forKey: balanceKey)
        if let lastCursor {
            UserDefaults.standard.set(lastCursor, forKey: cursorKey)
        } else {
            UserDefaults.standard.removeObject(forKey: cursorKey)
        }
        UserDefaults.standard.set(isBalancePossiblyOutOfDate, forKey: staleBalanceKey)
    }

    public func clearError() {
        networkError = nil
    }
}
