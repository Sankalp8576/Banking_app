//
//  ViewModel.swift
//  BunqAssignment
//

import Combine
import Foundation
import SwiftUI

@MainActor
public final class BankViewModel: ObservableObject {
    @Published var balance: Double = 1000.0
    @Published var transactions: [Transaction] = []
    @Published var localPaymentState: LocalPaymentState?
    @Published var networkError: String?

    private let service: BankServiceProtocol
    private let userDefaultsKey = "bunq.local.state"
    private let transactionsDefaultsKey = "bunq.local.txns"
    private let balanceDefaultsKey = "bunq.local.balance"
    private var lastCursor: Int?

    public init(service: BankServiceProtocol) {
        self.service = service
        loadFromDisk()
    }

    public func loadFromDisk() {
       
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey) {
            localPaymentState = try? JSONDecoder().decode(LocalPaymentState.self, from: data)
        }
        if let data = UserDefaults.standard.data(forKey: transactionsDefaultsKey),
           let savedTransactions = try? JSONDecoder().decode([Transaction].self, from: data) {
            transactions = savedTransactions
        }

        let savedBalance = UserDefaults.standard.integer(forKey: balanceDefaultsKey)
        if savedBalance != 0 {
            balance = Double(savedBalance) / 100
        }
    }

    public func sync() async {
        networkError = nil

        if case let .failedMidFlight(key, amount, destination, description) = localPaymentState {
            await retryPaymentFlight(
                key: key,
                amount: amount,
                destination: destination,
                description: description
            )
        }

        do {
            let response = try await service.fetchFeed(cursor: lastCursor)
            balance = Double(response.balanceCents) / 100
            lastCursor = response.cursor

            for transaction in response.transactions {
                upsert(transaction)

                if case let .apiPending(localTransaction) = localPaymentState,
                   localTransaction.id == transaction.id {
                    localPaymentState = nil
                }
            }
            saveToDisk()
        } catch {
            networkError = "Bank is unreachable. Out of date."
        }
    }

    public func initiatePayment(to destination: String, amountCents: Int, description: String) async {
        let idempotencyKey = UUID().uuidString
        networkError = nil
        localPaymentState = .unconfirmed(
            idempotencyKey: idempotencyKey,
            amount: amountCents,
            destination: destination,
            desc: description
        )
        saveToDisk()

        await executePaymentFlight(
            key: idempotencyKey,
            amount: amountCents,
            destination: destination,
            description: description
        )
    }

    private func executePaymentFlight(
        key: String,
        amount: Int,
        destination: String,
        description: String
    ) async {
        do {
            let response = try await service.createPayment(
                to: destination,
                amount: amount,
                description: description,
                key: key
            )
            upsert(response.transaction)
            localPaymentState = .apiPending(transaction: response.transaction)
            saveToDisk()
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
                URLError(.init(rawValue: error.code) ?? .unknown),
                key: key,
                amount: amount,
                destination: destination,
                description: description
            )
        } catch {
            localPaymentState = nil
            saveToDisk()
            networkError = error.localizedDescription
        }
    }

    private func retryPaymentFlight(
        key: String,
        amount: Int,
        destination: String,
        description: String
    ) async {
        await executePaymentFlight(
            key: key,
            amount: amount,
            destination: destination,
            description: description
        )
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
            networkError = "Connection lost. Tap Sync to verify."
        case .notConnectedToInternet:
            localPaymentState = nil
            networkError = "No connection. Payment cancelled."
        default:
            localPaymentState = nil
            networkError = error.localizedDescription
        }
        saveToDisk()
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
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        }
        if let data = try? JSONEncoder().encode(transactions) {
            UserDefaults.standard.set(data, forKey: transactionsDefaultsKey)
        }
        UserDefaults.standard.set(Int(balance * 100), forKey: balanceDefaultsKey)
    }

    public func clearError() {
        networkError = nil
    }
}
