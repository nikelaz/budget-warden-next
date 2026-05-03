import AppKit
import SwiftUI

struct WelcomeLeftColumn: View {
    let onCreateBudget: () -> Void
    let onOpenBudget: () -> Void
    let onConfigureVault: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 130, height: 130)
                .accessibilityHidden(true)
            
            Text("Budget Warden")
                .font(.largeTitle)
                .fontWeight(.semibold)
            
            VStack(alignment: .center, spacing: 10) {
                Button("Create New Budget", systemImage: "plus") {
                    onCreateBudget()
                }
                
                Button("Open Budget", systemImage: "folder") {
                    onOpenBudget()
                }
                
                Button("Configure Vault", systemImage: "externaldrive") {
                    onConfigureVault()
                }
            }
            
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}
