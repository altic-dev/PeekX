//
//  PeekXApp.swift
//  PeekX
//
//  Created by Barathwaj Anandan on 11/15/25.
//

import SwiftUI

@main
struct PeekXApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 600, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
