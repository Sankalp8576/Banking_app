//
//  ContentView.swift
//  BunqAssignment
//
//  Created by Sankalp Verma on 26/10/26.
//

import SwiftUI
struct ContentView: View {
    @StateObject var viewModel: BankViewModel
    
    @State private var recipient = "alex"
    @State private var amountString = "25.00"
    @State private var description = "lunch"
    
    init(viewModel: BankViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Balance Header
                    VStack(alignment: .leading) {
                        Text("Eva's Balance")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        Text(String(format: "$%.2f", viewModel.balance))
                            .font(.largeTitle)
                            .bold()
                        if viewModel.networkError != nil {
                            Text("⚠️ \(viewModel.networkError!)")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    
                    // Direct Action Controls
                    Button("🔄 Sync Account Data") {
                        Task { await viewModel.sync() }
                    }
                    .buttonStyle(.borderedProminent)
                    
                    // Local Payment Processing Status Block
                    if let pendingState = viewModel.localPaymentState {
                        VStack(alignment: .leading) {
                            Text("In-Flight / Local Queue Tracker:")
                                .font(.caption).bold()
                            switch pendingState {
                            case .unconfirmed(_, let amt, let dest, _):
                                Text("⏳ Unconfirmed: Sending $\(Double(amt)/100.0) to \(dest)...")
                            case .apiPending(let txn):
                                Text("🛰️ Pending at Bank: Txn ID \(txn.id) (\(txn.status.rawValue))")
                            case .failedMidFlight(_, let amt, let dest, _):
                                Text("❌ Lost Airway Response: $\(Double(amt)/100.0) to \(dest). Sync required.")
                            }
                        }
                        .padding(8)
                        .background(Color(.systemYellow).opacity(0.2))
                        .cornerRadius(6)
                    }

                    // Payment Transfer Card Form Structure
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Send Money").font(.headline)
                        Picker("Recipient", selection: $recipient) {
                            Text("Alex").tag("alex")
                            Text("Mila").tag("mila")
                            Text("Noor").tag("noor")
                        }.pickerStyle(.segmented)
                        
                        TextField("Amount (e.g. 25.00)", text: $amountString)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Description", text: $description)
                            .textFieldStyle(.roundedBorder)
                        
                        Button("Confirm & Send Transfer") {
                            let cents = Int((Double(amountString) ?? 0.0) * 100.0)
                            Task {
                                await viewModel.initiatePayment(to: recipient, amountCents: cents, description: description)
                            }
                        }
                        .disabled(viewModel.localPaymentState != nil)
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(8)
                    .shadow(radius: 1)

                    // Feed Transactions History Rows List Representation
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Transactions History Feed").font(.headline)
                        ForEach(viewModel.transactions.reversed()) { txn in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(txn.fromUsername) ➡️ \(txn.toUsername)")
                                        .font(.body).bold()
                                    Text(txn.description)
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(String(format: "$%.2f", Double(txn.amountCents)/100.0))
                                        .bold()
                                    Text(txn.status.rawValue.uppercased())
                                        .font(.caption2)
                                        .padding(4)
                                        .background(statusColor(txn.status))
                                        .cornerRadius(4)
                                }
                            }
                            Divider()
                        }
                    }
                }
                .padding()
            }
        }
    }

    private func statusColor(_ status: Transaction.Status) -> Color {
        switch status {
        case .pending: return .yellow.opacity(0.3)
        case .completed: return .green.opacity(0.3)
        case .rejected: return .red.opacity(0.3)
        }
    }
}

//
//#Preview {
//    ContentView()
//}
