import SwiftUI

@main
struct BudgetWardenApp: App {
    @StateObject private var store = BudgetStore()

    var body: some Scene {
        WelcomeWindow(store: store)
        MainWindow(store: store)
    }
}
