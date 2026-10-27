import SwiftUI

struct ContentView: View {
    @State private var viewModel: BankViewModel
    @State private var recipient = "alex"
    @State private var amountString = "25.00"
    @State private var paymentDescription = "lunch"

    init(viewModel: BankViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    BalanceHeader(
                        balanceCents: viewModel.balanceCents,
                        isPossiblyOutOfDate: viewModel.isBalancePossiblyOutOfDate,
                        errorMessage: viewModel.networkError
                    )
                }

                Section {
                    Button("Sync Account Data") {
                        Task { await viewModel.sync() }
                    }
                }

                if let state = viewModel.localPaymentState {
                    Section("Payment status") {
                        PaymentStateCard(
                            state: state,
                            retry: {
                                Task { await viewModel.retryNotSentPayment() }
                            }
                        )
                    }
                }

                Section("Send money") {
                    PaymentForm(
                        recipient: $recipient,
                        amountString: $amountString,
                        paymentDescription: $paymentDescription,
                        isSendDisabled: viewModel.localPaymentState != nil,
                        send: {
                            let amount = Decimal(string: amountString, locale: .current) ?? 0
                            let cents = NSDecimalNumber(decimal: amount * 100).intValue
                            Task {
                                await viewModel.initiatePayment(
                                    to: recipient,
                                    amountCents: cents,
                                    description: paymentDescription
                                )
                            }
                        }
                    )
                }

                Section("Transactions") {
                    ForEach(viewModel.transactions.reversed()) { transaction in
                        TransactionRow(transaction: transaction)
                    }
                }

                Section("Debug bank controls") {
                    Button("Settle Pending Payments") {
                        FakeBank.settlePendingPayments()
                    }
                    Button("Release Balance-Ahead Payments") {
                        FakeBank.releaseAheadPayments()
                    }
                    Button("Reject Latest Completed Payment") {
                        guard let transaction = viewModel.transactions.last(where: { $0.status == .completed }) else {
                            return
                        }
                        FakeBank.lateRejection = true
                        FakeBank.triggerLateRejection(
                            id: transaction.id,
                            reason: "The receiving bank refused it"
                        )
                    }
                }
            }
            .navigationTitle("Eva's Account")
        }
        .task {
            await viewModel.sync()
        }
    }
}

private struct BalanceHeader: View {
    let balanceCents: Int
    let isPossiblyOutOfDate: Bool
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Available balance")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Double(balanceCents) / 100, format: .currency(code: "USD"))
                .font(.largeTitle.bold())
            if isPossiblyOutOfDate {
                Label("Possibly out of date", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct PaymentStateCard: View {
    let state: LocalPaymentState
    let retry: () -> Void

    var body: some View {
        switch state {
        case .unconfirmed(_, let amount, let destination, _):
            Label(
                "Sending \(formattedAmount(amount)) to \(destination). Not confirmed yet.",
                systemImage: "arrow.triangle.2.circlepath"
            )
        case .apiPending(let transaction):
            Label(
                "Payment to \(transaction.toUsername) is pending at the bank.",
                systemImage: "clock"
            )
        case .failedMidFlight(_, let amount, let destination, _):
            Label(
                "Payment of \(formattedAmount(amount)) to \(destination) is unconfirmed. Sync to verify it.",
                systemImage: "questionmark.circle"
            )
        case .notSent(_, let amount, let destination, _):
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Payment of \(formattedAmount(amount)) to \(destination) was not sent.",
                    systemImage: "wifi.slash"
                )
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
            }
        }
    }

    private func formattedAmount(_ cents: Int) -> String {
        (Double(cents) / 100).formatted(.currency(code: "USD"))
    }
}

private struct PaymentForm: View {
    @Binding var recipient: String
    @Binding var amountString: String
    @Binding var paymentDescription: String
    let isSendDisabled: Bool
    let send: () -> Void

    var body: some View {
        Picker("Recipient", selection: $recipient) {
            Text("Alex").tag("alex")
            Text("Mila").tag("mila")
            Text("Noor").tag("noor")
        }

        TextField("Amount", text: $amountString)
            .keyboardType(.decimalPad)

        TextField("Description", text: $paymentDescription)

        Button("Send payment", action: send)
            .disabled(isSendDisabled)
    }
}

private struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(transaction.fromUsername) → \(transaction.toUsername)")
                    .font(.headline)
                Text(transaction.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let rejectionReason = transaction.rejectionReason {
                    Text(rejectionReason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Double(transaction.amountCents) / 100, format: .currency(code: "USD"))
                Text(transaction.status.rawValue)
                    .font(.caption)
                    .foregroundStyle(statusColor(transaction.status))
            }
        }
    }

    private func statusColor(_ status: Transaction.Status) -> Color {
        switch status {
        case .pending:
            .orange
        case .completed:
            .green
        case .rejected:
            .red
        }
    }
}
