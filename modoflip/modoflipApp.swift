//
//  modoflipApp.swift
//  modoflip
//
//  Created by Orszagh Bihari Sandor  on 2025. 09. 24..
//

import SwiftUI

@main
struct modoflipApp: App {
    @StateObject var store = FlashcardStore()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
