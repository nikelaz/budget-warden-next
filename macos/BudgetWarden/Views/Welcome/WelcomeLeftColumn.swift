/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import AppKit
import SwiftUI

struct WelcomeLeftColumn: View {
    let store: BWStore
    let windowStore: BWWindowStore
    let openMainWindow: () -> Void

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
                    windowStore.showCreateBudget() 
                }
                
                Button("Open Budget", systemImage: "folder") {
                    let budgetOpened = store.openBudgetInPlace() 
                    if budgetOpened { 
                        openMainWindow()
                    }
                }
                
                Button("Configure Vault", systemImage: "externaldrive") {
                    windowStore.showVaultSetup()
                }
            }
            
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}
