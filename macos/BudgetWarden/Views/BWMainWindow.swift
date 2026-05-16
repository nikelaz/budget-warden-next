import SwiftUI

struct BWMainWindow: Scene {
    @EnvironmentObject var store: BWStore

    @StateObject private var windowStore = BWWindowStore()

    var body: some Scene {
        Window("Budget Warden", id: "window-main") {
            if store.currentBudget == nil {
                Text("No budget selected")
            }
            else {
                Text("Current Budget: \(store.currentBudget!.title)")
            }
        }
    }
}
