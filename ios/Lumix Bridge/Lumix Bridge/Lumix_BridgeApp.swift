//
//  Lumix_BridgeApp.swift
//  Lumix Bridge
//
//  Created by Elijah Bantugan on 8/28/26.
//

import SwiftUI

@main
struct Lumix_BridgeApp: App {
    /// One session for the whole app lifetime. The camera expects a single
    /// controller that stays connected — see ARCHITECTURE.md.
    @State private var model = BridgeModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}
