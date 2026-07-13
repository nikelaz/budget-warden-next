/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import CloudKit
import SwiftUI
import UIKit

struct BWPreparedCloudShare: Identifiable {
    let id = UUID()
    let share: CKShare
}

struct BWPreparingCloudShareView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.15)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)

                Text("Preparing iCloud Sharing…")
                    .font(.headline)

                Text("Budget Warden is preparing the budget for collaboration. This may take a moment.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .shadow(radius: 12)
        }
        .accessibilityElement(children: .combine)
    }
}

struct BWCloudSharingView: UIViewControllerRepresentable {
    let share: CKShare

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(
            share: share,
            container: CKContainer(identifier: "iCloud.com.lazarovco.BudgetWarden")
        )
        controller.delegate = context.coordinator
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func itemTitle(for controller: UICloudSharingController) -> String? {
            controller.share?[CKShare.SystemFieldKey.title] as? String
        }

        func cloudSharingController(
            _ controller: UICloudSharingController,
            failedToSaveShareWithError error: any Error
        ) {
        }

        func cloudSharingControllerDidSaveShare(_ controller: UICloudSharingController) {
        }

        func cloudSharingControllerDidStopSharing(_ controller: UICloudSharingController) {
        }
    }
}
