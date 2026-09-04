//
//  nuboApp.swift
//  nubo
//
//  Created by Álvaro García Pizarro on 04/09/2026.
//

import SwiftUI
import CoreData

@main
struct nuboApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
