/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import AppKit
import CloudKit
import SwiftUI

struct BWPreparingCloudShareView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.15)

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

@MainActor
final class BWMacCloudSharing: NSObject, NSCloudSharingServiceDelegate {
    static let shared = BWMacCloudSharing()

    private override init() {
    }

    func present(_ share: CKShare) {
        guard let service = NSSharingService(named: .cloudSharing) else {
            return
        }

        let provider = NSItemProvider()
        let title = share[CKShare.SystemFieldKey.title] as? String ?? "Budget"

        provider.suggestedName = title
        service.subject = title

        if share[CKShare.SystemFieldKey.thumbnailImageData] == nil,
           let iconData = applicationIconPNGData() {
            share[CKShare.SystemFieldKey.thumbnailImageData] = iconData as CKRecordValue
        }

        let options = CKAllowedSharingOptions(
            allowedParticipantPermissionOptions: .readWrite,
            allowedParticipantAccessOptions: .specifiedRecipientsOnly
        )
        provider.registerCKShare(
            share,
            container: CKContainer(identifier: "iCloud.com.lazarovco.BudgetWarden"),
            allowedSharingOptions: options
        )
        service.delegate = self
        service.perform(withItems: [provider])
    }

    private func applicationIconPNGData() -> Data? {
        let size = NSSize(width: 128, height: 128)
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        NSApplication.shared.applicationIconImage.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        thumbnail.unlockFocus()

        guard let tiffData = thumbnail.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    nonisolated func options(
        for sharingService: NSSharingService,
        share: NSItemProvider
    ) -> NSSharingService.CloudKitOptions {
        [.allowPrivate, .allowReadWrite]
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didSave share: CKShare) {
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) {
    }
}
