//
//  BunqAssignmentTests.swift
//  BunqAssignmentTests
//
//  Created by Sankalp Verma on 26/10/26.
//

import XCTest
@testable import BunqAssignment

@MainActor
class BunqAssignmentTests: XCTestCase {
    var configuration: URLSessionConfiguration!
    var session: URLSession!
    var service: BankService!
    var viewModel: BankViewModel!

    override func setUp() {
        super.setUp()
        // Standard injection design context for isolated testing protocols
        configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeBank.self]
        session = URLSession(configuration: configuration)
        service = BankService(session: session)
        
        FakeBank.reset()
        
        // Purge disk layer clean
        UserDefaults.standard.removeObject(forKey: "bunq.local.state")
        UserDefaults.standard.removeObject(forKey: "bunq.local.txns")
        UserDefaults.standard.removeObject(forKey: "bunq.local.balance")
        
        viewModel = BankViewModel(service: service)
    }

    func testScenario1_HappyPath() async {
        XCTAssertEqual(viewModel.balance, 1000.0)
        
        // Step 1 & 2: Initiate transfer transaction path validation triggers unconfirmed display instantly
        let paymentTask = Task {
            await viewModel.initiatePayment(to: "alex", amountCents: 2500, description: "lunch")
        }
        
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(viewModel.localPaymentState) // Displays as unconfirmed inside UI boundaries
        
        await paymentTask.value
        
        XCTAssertEqual(FakeBank.transactions.count, 1)
        XCTAssertEqual(FakeBank.transactions.first?.status, .pending)
        
        // Step 3: Settle the pending item inside structural ledger elements
        FakeBank.settlePendingPayments()
        
        // Step 4: Perform verification account fetch sweeps
        await viewModel.sync()
        XCTAssertEqual(viewModel.balance, 975.0)
        XCTAssertEqual(viewModel.transactions.count, 1)
        XCTAssertEqual(viewModel.transactions.first?.status, .completed)
    }

    func testScenario2_LostAnswer() async {
        FakeBank.lostAnswer = true
        
        await viewModel.initiatePayment(to: "alex", amountCents: 2500, description: "lunch")
        
        // Verify payment structural execution happened inside Fake ledger safely despite local loss context
        XCTAssertEqual(FakeBank.transactions.count, 1)
        
        // Directly check if the enum matches what we expect
        if case .failedMidFlight(_, let amount, let destination, let desc) = viewModel.localPaymentState {
            XCTAssertEqual(amount, 2500)
            XCTAssertEqual(destination, "alex")
            XCTAssertEqual(desc, "lunch")
        } else {
            XCTFail("Expected state to be .failedMidFlight but got \(String(describing: viewModel.localPaymentState))")
        }
        
        // Recovery pathway
        FakeBank.lostAnswer = false
        FakeBank.settlePendingPayments()
        
        await viewModel.sync()
        XCTAssertEqual(viewModel.balance, 975.0)
        XCTAssertNil(viewModel.localPaymentState)
    }

    }
}
