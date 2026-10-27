//
//  BunqAssignmentApp.swift
//  BunqAssignment
//
//  Created by Sankalp Verma on 26/10/26.
//

import SwiftUI

@main
struct BunqAssignmentApp: App {
    // 1. Declare properties at the App level
    private let service: BankService
    private let viewModel: BankViewModel

    init() {
        // 2. Register our Custom URLProtocol globally on the shared session
        URLProtocol.registerClass(FakeBank.self)
        
        // 3. Configure the session cleanly inside init()
        let config = URLSessionConfiguration.default
        config.protocolClasses = [FakeBank.self]
        
        let session = URLSession(configuration: config)
        let initializedService = BankService(session: session)
        
        // 4. Assign properties
        self.service = initializedService
        self.viewModel = BankViewModel(service: initializedService)
    }

    var body: some Scene {
        WindowGroup {
            // 5. Keep the view builder pure and free of configuration code
            ContentView(viewModel: viewModel)
        }
    }
}
