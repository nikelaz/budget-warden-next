/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import BudgetWardenAppleCore
import CloudKit
import UIKit

extension Notification.Name {
    static let budgetWardenAcceptedCloudShare = Notification.Name("BudgetWardenAcceptedCloudShare")
}

enum BWPendingCloudShare {
    private static let recordNameKey = "BWI_PENDING_CLOUD_SHARE_RECORD_NAME"
    private static let zoneNameKey = "BWI_PENDING_CLOUD_SHARE_ZONE_NAME"
    private static let ownerNameKey = "BWI_PENDING_CLOUD_SHARE_OWNER_NAME"

    static var recordID: CKRecord.ID? {
        guard let recordName = UserDefaults.standard.string(forKey: recordNameKey),
              let zoneName = UserDefaults.standard.string(forKey: zoneNameKey),
              let ownerName = UserDefaults.standard.string(forKey: ownerNameKey)
        else {
            return nil
        }

        return CKRecord.ID(
            recordName: recordName,
            zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
        )
    }

    static func store(recordID: CKRecord.ID) {
        UserDefaults.standard.set(recordID.recordName, forKey: recordNameKey)
        UserDefaults.standard.set(recordID.zoneID.zoneName, forKey: zoneNameKey)
        UserDefaults.standard.set(recordID.zoneID.ownerName, forKey: ownerNameKey)
    }

    static func clear(recordID: CKRecord.ID) {
        guard self.recordID == recordID else {
            return
        }

        UserDefaults.standard.removeObject(forKey: recordNameKey)
        UserDefaults.standard.removeObject(forKey: zoneNameKey)
        UserDefaults.standard.removeObject(forKey: ownerNameKey)
    }
}

final class BWSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            accept(metadata)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
    ) {
        accept(metadata)
    }

    private func accept(_ metadata: CKShare.Metadata) {
        guard let recordID = metadata.hierarchicalRootRecordID else {
            return
        }

        BWPendingCloudShare.store(recordID: recordID)

        Task {
            _ = await BWCloudBudgetRepository().acceptShare(metadata)

            await MainActor.run {
                NotificationCenter.default.post(
                    name: .budgetWardenAcceptedCloudShare,
                    object: recordID
                )
            }
        }
    }
}

final class BWAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = BWSceneDelegate.self
        return configuration
    }
}
